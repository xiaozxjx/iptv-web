'use strict';

// 本地服务：静态页面 + m3u 反代 + HLS playlist 稳定化 + 分片转发 + 健康检查
// 上游 ysp-live 每次刷新会把所有分片的签名 token 换掉，hls.js 会因
// "同一 SN 对应不同 URL" 抛 levelParsingError(media sequence mismatch)。
// 这里把分片改写成同源 /seg/<channel>/<sn>，SN 恒定、URL 恒定，
// 真实地址由服务端用最新 token 转发，从根上避开该问题。
// 默认源是本机 ysp-live.py（端口 20345），由 start.bat 一并拉起。

const http = require('http');
const https = require('https');
const fs = require('fs');
const path = require('path');
const os = require('os');

// 统一日志时间戳：[YYYY-MM-DD HH:MM:SS]
function stamp() {
  const d = new Date();
  const p = function (n) { return String(n).padStart(2, '0'); };
  return '[' + d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate()) + ' ' +
    p(d.getHours()) + ':' + p(d.getMinutes()) + ':' + p(d.getSeconds()) + ']';
}
function log() { console.log(stamp() + ' ' + Array.prototype.slice.call(arguments).join(' ')); }
function logErr() { console.error(stamp() + ' ' + Array.prototype.slice.call(arguments).join(' ')); }

const ROOT = __dirname;
const PORT = Number(process.env.PORT || 8088);
// 0.0.0.0 = 本机 + 局域网都能访问；只想本机访问时设 HOST=127.0.0.1
const HOST = process.env.HOST || '0.0.0.0';
const DEFAULT_SRC = process.env.M3U_SRC || 'http://127.0.0.1:20345/all.m3u';

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'application/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.m3u': 'application/vnd.apple.mpegurl; charset=utf-8',
  '.m3u8': 'application/vnd.apple.mpegurl; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.ico': 'image/x-icon'
};

function send(res, code, body, headers) {
  const h = Object.assign({
    'Cache-Control': 'no-store',
    'Access-Control-Allow-Origin': '*'
  }, headers || {});
  res.writeHead(code, h);
  res.end(body);
}
function json(res, code, obj) {
  send(res, code, JSON.stringify(obj), { 'Content-Type': 'application/json; charset=utf-8' });
}

/* ---------------- 上游请求 ---------------- */
function getUpstream(urlStr, cb, timeoutMs) {
  let target;
  try { target = new URL(urlStr); } catch (e) { return cb(new Error('上游地址格式不对')); }
  if (target.protocol !== 'http:' && target.protocol !== 'https:') {
    return cb(new Error('只支持 http/https 上游'));
  }
  const client = target.protocol === 'https:' ? https : http;
  const req = client.get(target, {
    timeout: timeoutMs || 8000,
    headers: { 'User-Agent': 'iptv-web/1.0', 'Accept': '*/*' }
  }, (up) => {
    const chunks = [];
    up.on('data', (c) => chunks.push(c));
    up.on('end', () => cb(null, up.statusCode, Buffer.concat(chunks), up.headers));
  });
  req.on('timeout', () => req.destroy(new Error('上游超时')));
  req.on('error', (e) => cb(e));
}
function srcOf(req) {
  const u = new URL(req.url, 'http://localhost');
  return u.searchParams.get('src') || u.searchParams.get('u') || DEFAULT_SRC;
}
function isLocalSrc(src) {
  return /^https?:\/\/(?:127\.0\.0\.1|localhost):\d+\//i.test(src);
}

/* ---------------- m3u（频道列表） ---------------- */
function handleM3U(req, res, asJson) {
  const src = srcOf(req);
  const started = Date.now();
  getUpstream(src, (err, status, buf) => {
    if (err) return json(res, 502, { ok: false, error: err.message, upstream: src });
    if (status !== 200) return json(res, 502, { ok: false, error: '源站 HTTP ' + status, upstream: src });
    const text = buf.toString('utf8');
    if (asJson) {
      return json(res, 200, {
        ok: true, ms: Date.now() - started, bytes: buf.length,
        channels: (text.match(/^https?:\/\//gm) || []).length, upstream: src
      });
    }
    // ysp-live 按请求 Host 生成频道地址，默认就是 127.0.0.1:20345。
    // 从局域网其它设备访问网页时，把它换成网页主机 + 同一端口，
    // 否则客户端会把 127.0.0.1 指到自己身上。
    let body = buf;
    const m = src.match(/^https?:\/\/(?:127\.0\.0\.1|localhost):(\d+)\//i);
    const host = (req.headers.host || '').split(':')[0].trim();
    if (m && host && host !== '127.0.0.1' && host !== 'localhost') {
      const from = new RegExp('http://(?:127\\.0\\.0\\.1|localhost):' + m[1] + '/', 'g');
      body = Buffer.from(text.replace(from, 'http://' + host + ':' + m[1] + '/'), 'utf8');
    }
    send(res, 200, body, {
      'Content-Type': 'application/vnd.apple.mpegurl; charset=utf-8',
      'X-Upstream-Ms': String(Date.now() - started)
    });
  });
}

/* ---------------- HLS playlist 稳定化 ---------------- */
const segMap = new Map();        // channelKey -> Map(虚拟 sn -> 真实分片 URL)
const srcMap = new Map();        // channelKey -> 上游 m3u8 地址
const playlistCache = new Map(); // channelKey -> { body, ts } 上一次成功生成的 playlist
const seqState = new Map();      // channelKey -> { outSeq, lastPdt, realSeq } 单调递增的虚拟 SN
const PLAYLIST_CACHE_TTL = 30000; // 只用于短时上游抖动兜底；过期的旧清单不能再喂给刚切回的频道

function pdtMs(s) {
  if (!s) return null;
  const t = Date.parse(s);
  return Number.isFinite(t) ? t : null;
}

function chanKey(u) {
  try {
    const t = new URL(u);
    const f = t.pathname.split('/').pop() || 'ch';
    const base = f.replace(/\.m3u8.*$/i, '').replace(/[^A-Za-z0-9_-]/g, '') || 'ch';
    // 不同源有同名频道（cctv1），key 必须带主机，否则分片映射 / 缓存会串源
    const host = (t.host || 'src').replace(/[^A-Za-z0-9_-]/g, '');
    return host + '_' + base;
  } catch (e) { return 'ch'; }
}

function parsePlaylist(text) {
  let seq = 0, td = 10, dur = null, pdt = null;
  const frags = [];
  for (const raw of text.split(/\r?\n/)) {
    const l = raw.trim();
    if (!l) continue;
    let m;
    if ((m = l.match(/^#EXT-X-MEDIA-SEQUENCE:\s*(\d+)/))) seq = Number(m[1]);
    else if ((m = l.match(/^#EXT-X-TARGETDURATION:\s*(\d+)/))) td = Number(m[1]);
    else if ((m = l.match(/^#EXTINF:\s*([0-9.]+)/))) dur = m[1];
    else if ((m = l.match(/^#EXT-X-PROGRAM-DATE-TIME:\s*(.+)/))) pdt = m[1].trim();
    else if (/^https?:\/\//i.test(l)) {
      frags.push({ url: l, dur: dur || '5.000', pdt: pdt });
      dur = null;
    }
  }
  return { seq: seq, td: td, frags: frags,
           lastPdt: frags.length ? frags[frags.length - 1].pdt : null };
}
function validPlaylist(p) {
  return p.frags.length >= 2 && p.frags.every(function (f) {
    return /\.(ts|m4s|mp4)(\?|$)/i.test(f.url);
  });
}
// 上游 worker 每 3 小时被监督器重启后内存窗口清空，MEDIA-SEQUENCE 会倒退
// （实测 45 -> 41）。倒退的 SN 直接给 hls.js 会触发 levelParsingError、销毁重建
// 播放器，画面就卡一下。这里按 PROGRAM-DATE-TIME 算出真正新增的分片数，生成
// 只增不减的虚拟 SN；/seg 路径不变，浏览器完全看不到上游重启或换签名。
function nextOutSeq(p, key) {
  const st = seqState.get(key);
  const curPdt = pdtMs(p.lastPdt);
  if (!st) {
    seqState.set(key, { outSeq: p.seq, lastPdt: curPdt, realSeq: p.seq });
    return p.seq;
  }
  let advance = 0;
  if (st.lastPdt !== null && curPdt !== null) {
    // 只有时间晚于上一份清单末尾的分片才算新增；重启拉回旧窗口时 advance=0
    advance = p.frags.filter(function (f) {
      const t = pdtMs(f.pdt);
      return t !== null && t > st.lastPdt;
    }).length;
  } else {
    // 上游没给 PDT：退回真实 SN 的增量，但只允许前进，绝不回退
    advance = Math.max(0, p.seq - st.realSeq);
  }
  const outSeq = st.outSeq + advance;
  const keepPdt = curPdt === null ? st.lastPdt
    : (st.lastPdt === null ? curPdt : Math.max(st.lastPdt, curPdt));
  seqState.set(key, { outSeq: outSeq, lastPdt: keepPdt, realSeq: p.seq });
  return outSeq;
}

function buildPlaylist(p, key, advance) {
  // /seg 冷启动兜底只刷新 URL 映射，不推进虚拟 SN，避免和 /hls 各推一次造成跳号
  const st = seqState.get(key);
  const outSeq = advance ? nextOutSeq(p, key) : (st ? st.outSeq : p.seq);
  let map = segMap.get(key);
  if (!map) { map = new Map(); segMap.set(key, map); }
  const out = [
    '#EXTM3U',
    '#EXT-X-VERSION:3',
    '#EXT-X-TARGETDURATION:' + p.td,
    '#EXT-X-MEDIA-SEQUENCE:' + outSeq
  ];
  p.frags.forEach(function (f, i) {
    const sn = outSeq + i;
    map.set(sn, f.url);
    out.push('#EXTINF:' + f.dur + ',', '/seg/' + key + '/' + sn);
  });
  // 上游 SN 增长快于真实时间，保留更宽的映射窗口，避免旧分片请求 404
  const min = outSeq - 400;
  for (const k of map.keys()) if (k < min) map.delete(k);
  return out.join('\n') + '\n';
}

function handleHls(req, res) {
  const src = srcOf(req);
  const key = chanKey(src);
  srcMap.set(key, src);
  // 本地 ysp-live 是懒加载：第一次请求某个频道会同步去拉 JCE/bkliveinfo，
  // 可能返回 503「暂无数据，请稍后重试」，给更长的超时和更多次重试等它预热。
  const local = isLocalSrc(src);
  const timeout = local ? 15000 : 6000;
  const maxRetry = local ? 4 : 2;

  function attempt(n) {
    getUpstream(src, function (err, status, buf) {
      if (!err && status === 200) {
        const p = parsePlaylist(buf.toString('utf8'));
        if (validPlaylist(p)) {
          const body = buildPlaylist(p, key, true);
          playlistCache.set(key, { body: body, ts: Date.now() });
          const st = seqState.get(key);
          return send(res, 200, body, {
            'Content-Type': 'application/vnd.apple.mpegurl; charset=utf-8',
            'X-Playlist-Sn': String(p.seq),
            'X-Playlist-Vsn': String(st ? st.outSeq : p.seq),
            'X-Playlist-Frags': String(p.frags.length)
          });
        }
      }
      if (n < maxRetry) {
        return setTimeout(function () { attempt(n + 1); }, Math.min(300 * (n + 1), 1200));
      }
      const cached = playlistCache.get(key);
      if (cached && Date.now() - cached.ts < PLAYLIST_CACHE_TTL) {
        return send(res, 200, cached.body, {
          'Content-Type': 'application/vnd.apple.mpegurl; charset=utf-8',
          'X-Playlist-Fallback': 'cached'
        });
      }
      playlistCache.delete(key);   // 过期缓存不留，避免下次又返回很久以前的内容
      return json(res, 502, {
        error: '上游 playlist 不可用',
        status: status || 0,
        detail: err ? err.message : '格式校验未通过'
      });
    }, timeout);
  }
  attempt(0);
}

/* ---------------- 分片转发 ---------------- */
function pipeSegment(res, url) {
  let target;
  try { target = new URL(url); } catch (e) { return send(res, 502, 'bad segment url'); }
  const client = target.protocol === 'https:' ? https : http;
  const up = client.get(target, {
    timeout: 20000,
    headers: { 'User-Agent': 'iptv-web/1.0', 'Accept': '*/*' }
  }, function (r) {
    if (r.statusCode !== 200 && r.statusCode !== 206) {
      r.resume();
      return send(res, 502, 'CDN HTTP ' + r.statusCode, { 'Content-Type': 'text/plain; charset=utf-8' });
    }
    const h = {
      'Content-Type': r.headers['content-type'] || 'video/MP2T',
      'Access-Control-Allow-Origin': '*',
      'Cache-Control': 'no-store',
      'Accept-Ranges': 'bytes'
    };
    if (r.headers['content-length']) h['Content-Length'] = r.headers['content-length'];
    res.writeHead(r.statusCode, h);
    r.pipe(res);
  });
  up.on('timeout', () => up.destroy(new Error('CDN 超时')));
  up.on('error', function (e) {
    if (!res.headersSent) send(res, 502, 'CDN 错误: ' + e.message, { 'Content-Type': 'text/plain; charset=utf-8' });
    else res.destroy();
  });
  res.on('close', function () { if (!res.writableEnded) up.destroy(); });
}

function handleSeg(req, res, pathname) {
  const parts = pathname.split('/');
  const key = parts[2];
  const sn = Number(parts[3]);
  if (!key || !Number.isInteger(sn)) return send(res, 400, 'bad segment path');

  const map = segMap.get(key);
  let url = map && map.get(sn);
  if (url) return pipeSegment(res, url);

  // 冷启动或映射被清理：按缓存的上游地址刷新一次再试
  const src = srcMap.get(key);
  if (!src) return send(res, 404, 'segment not found');
  getUpstream(src, function (err, status, buf) {
    if (!err && status === 200) {
      const p = parsePlaylist(buf.toString('utf8'));
      if (validPlaylist(p)) {
        buildPlaylist(p, key, false);
        url = segMap.get(key).get(sn);
      }
    }
    if (url) pipeSegment(res, url);
    else send(res, 404, 'segment expired');
  }, isLocalSrc(src) ? 15000 : 6000);
}

/* ---------------- 静态文件 ---------------- */
function serveStatic(req, res) {
  const pathname = decodeURIComponent(new URL(req.url, 'http://localhost').pathname);
  const rel = pathname === '/' ? 'index.html' : pathname.replace(/^\/+/, '');
  const file = path.resolve(ROOT, rel);
  if (!file.startsWith(ROOT + path.sep) && file !== path.join(ROOT, 'index.html')) {
    return send(res, 403, 'Forbidden', { 'Content-Type': 'text/plain; charset=utf-8' });
  }
  fs.readFile(file, function (err, buf) {
    if (err) return send(res, 404, 'Not Found', { 'Content-Type': 'text/plain; charset=utf-8' });
    send(res, 200, buf, { 'Content-Type': MIME[path.extname(file).toLowerCase()] || 'application/octet-stream' });
  });
}

/* ---------------- 路由 ---------------- */
const server = http.createServer(function (req, res) {
  const pathname = new URL(req.url, 'http://localhost').pathname;
  if (pathname === '/m3u') return handleM3U(req, res, false);
  if (pathname === '/health') return handleM3U(req, res, true);
  if (pathname === '/config') return json(res, 200, { defaultSrc: DEFAULT_SRC });
  if (pathname === '/hls') return handleHls(req, res);
  if (pathname.indexOf('/seg/') === 0) return handleSeg(req, res, pathname);
  return serveStatic(req, res);
});

server.on('error', function (e) {
  if (e.code === 'EADDRINUSE') logErr('端口 ' + PORT + ' 被占用，换一个：PORT=8089 node server.js');
  else logErr(e.message);
  process.exit(1);
});
server.listen(PORT, HOST, function () {
  log('IPTV 网页已启动: http://127.0.0.1:' + PORT);
  if (HOST === '0.0.0.0' || HOST === '::') {
    const ifaces = os.networkInterfaces();
    Object.keys(ifaces).forEach(function (name) {
      if (/vmware|virtual|loopback|hyper-v|wsl|docker/i.test(name)) return;
      (ifaces[name] || []).forEach(function (i) {
        if (!i.internal && (i.family === 'IPv4' || i.family === 4)) {
          log('局域网地址: http://' + i.address + ':' + PORT + ' (' + name + ')');
        }
      });
    });
  }
  log('默认源: ' + DEFAULT_SRC);
  log('HLS 已开启 playlist 稳定化（/hls + /seg）');
});

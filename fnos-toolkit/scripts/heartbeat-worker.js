/**
 * ============================================================
 * 网络告警 · Cloudflare Worker v3（微信 + 邮件，两个通道）
 *
 * 唯一通知出口：
 *   - NAS 的本地告警通过 POST /notify 发微信（NAS 自己发邮件，不重复）
 *   - NAS 完全离线时，本 Worker 用 微信 + Resend 邮件 双发
 *
 * 接口：
 *   GET  /                 健康检查
 *   GET  /ping?k=SECRET    NAS 心跳，记录时间戳
 *   POST /notify?k=SECRET  NAS 告警 → 只发微信
 *        body: {"title":"...","body":"..."}
 *   GET  /test?k=SECRET    立即测试全部通道，返回用了哪些
 *
 * 定时（Cron 每 5 分钟）：
 *   超过 ALERT_AFTER_SEC 没心跳 → 微信 + 邮件告警（失败下轮重试）
 *   心跳恢复 → 微信 + 邮件「已恢复」
 *
 * 环境变量：
 *   SECRET                   必填，防刷
 *   HEARTBEAT_KV             必填，KV 绑定
 *   NODE_NAME                设备名，默认 NAS
 *   ALERT_AFTER_SEC          判定掉线阈值，默认 600
 *   WX_APPID / WX_SECRET / WX_OPENID / WX_TEMPLATE_ID   微信通道
 *   RESEND_API_KEY / MAIL_FROM / MAIL_TO                邮件通道（断网场景用）
 * ============================================================
 */

const KEY_LAST = 'last_beat';
const KEY_ALERTING = 'alerting';
const KEY_WX_TOKEN = 'wx_token';

function fmtGap(ms) {
  const min = Math.round(ms / 60000);
  if (min >= 60) return `${Math.floor(min / 60)} 小时 ${min % 60} 分钟`;
  return `${min} 分钟`;
}

// ---------- 微信模板消息 ----------
async function sendWechat(env, title, content) {
  if (!env.WX_APPID || !env.WX_SECRET || !env.WX_OPENID || !env.WX_TEMPLATE_ID) {
    return { ok: false, reason: 'wechat:missing-env' };
  }

  const getToken = async (force) => {
    if (!force) {
      const cached = await env.HEARTBEAT_KV.get(KEY_WX_TOKEN);
      if (cached) return cached;
    }
    const r = await fetch(
      `https://api.weixin.qq.com/cgi-bin/token?grant_type=client_credential&appid=${env.WX_APPID}&secret=${env.WX_SECRET}`
    );
    const j = await r.json();
    if (!j.access_token) return null;
    await env.HEARTBEAT_KV.put(KEY_WX_TOKEN, j.access_token, { expirationTtl: 6900 });
    return j.access_token;
  };

  const now = new Date(Date.now() + 8 * 3600 * 1000).toISOString().slice(0, 19).replace('T', ' ');
  const payload = {
    touser: env.WX_OPENID,
    template_id: env.WX_TEMPLATE_ID,
    data: {
      first: { value: String(title).slice(0, 60) },
      keyword1: { value: String(content).slice(0, 60) },
      keyword2: { value: now },
      remark: { value: 'Cloudflare 网络监控' },
    },
  };

  for (const force of [false, true]) {
    const token = await getToken(force);
    if (!token) return { ok: false, reason: 'wechat:token-failed' };
    const r = await fetch(
      `https://api.weixin.qq.com/cgi-bin/message/template/send?access_token=${token}`,
      {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify(payload),
      }
    );
    const j = await r.json();
    if (j.errcode === 0) return { ok: true, channel: 'wechat' };
    if (j.errcode === 40001 || j.errcode === 42001) {
      await env.HEARTBEAT_KV.delete(KEY_WX_TOKEN);
      continue;
    }
    return { ok: false, reason: `wechat:errcode-${j.errcode}` };
  }
  return { ok: false, reason: 'wechat:retry-failed' };
}

// ---------- Resend 邮件 ----------
async function sendMail(env, title, content) {
  if (!env.RESEND_API_KEY || !env.MAIL_FROM || !env.MAIL_TO) {
    return { ok: false, reason: 'mail:missing-env' };
  }
  try {
    const r = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: {
        authorization: `Bearer ${env.RESEND_API_KEY}`,
        'content-type': 'application/json',
      },
      body: JSON.stringify({
        from: env.MAIL_FROM,
        to: [env.MAIL_TO],
        subject: `[${env.NODE_NAME || 'NAS'}] ${title}`,
        text: content,
      }),
    });
    if (r.ok) return { ok: true, channel: 'mail' };
    const t = await r.text();
    return { ok: false, reason: `mail:http-${r.status}-${t.slice(0, 80)}` };
  } catch (e) {
    return { ok: false, reason: 'mail:exception' };
  }
}

// ---------- 推送入口 ----------
async function push(env, title, content, opts = {}) {
  const wantMail = opts.mail !== false; // 默认发邮件
  const tasks = [sendWechat(env, title, content)];
  if (wantMail) tasks.push(sendMail(env, title, content));

  const results = await Promise.all(tasks);
  const okList = results.filter((r) => r.ok).map((r) => r.channel);
  const fails = results.filter((r) => !r.ok && !/missing-env/.test(r.reason)).map((r) => r.reason);

  console.log('push ok:', okList.join(',') || 'none', '| failed:', fails.join(' | ') || 'none');
  return { ok: okList.length > 0, channel: okList.join(','), reason: fails.join(' | ') };
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const needSecret = ['/ping', '/notify', '/test'].includes(url.pathname);
    if (needSecret && (!env.SECRET || url.searchParams.get('k') !== env.SECRET)) {
      return new Response('forbidden', { status: 403 });
    }

    // 心跳
    if (url.pathname === '/ping') {
      const now = Date.now();
      const prevLast = parseInt((await env.HEARTBEAT_KV.get(KEY_LAST)) || '0', 10);
      const wasAlerting = (await env.HEARTBEAT_KV.get(KEY_ALERTING)) === 'true';

      await env.HEARTBEAT_KV.put(KEY_LAST, String(now));

      if (wasAlerting) {
        await env.HEARTBEAT_KV.put(KEY_ALERTING, 'false');
        const gap = prevLast > 0 ? now - prevLast : 0;
        const name = env.NODE_NAME || 'NAS';
        const r = await push(
          env,
          `${name} 网络已恢复`,
          `外部心跳已重新收到。` + (gap > 0 ? `本次中断约 ${fmtGap(gap)}。` : '')
        );
        return new Response('ok' + (r.ok ? ':' + r.channel : ':no-channel'), { status: 200 });
      }
      return new Response('ok', { status: 200 });
    }

    // NAS 本地告警：只发微信（邮件由 NAS 自己发，避免重复）
    if (url.pathname === '/notify') {
      let title = url.searchParams.get('title') || '';
      let body = url.searchParams.get('body') || '';
      if (request.method === 'POST') {
        try {
          const j = await request.json();
          title = j.title || title;
          body = j.body || body;
        } catch (e) {
          /* 非 JSON 就沿用 query 参数 */
        }
      }
      if (!title) return new Response('missing title', { status: 400 });

      const r = await push(env, title, body, { mail: false });
      return new Response(r.ok ? `sent:${r.channel}` : `failed:${r.reason}`, {
        status: r.ok ? 200 : 500,
      });
    }

    // 立即测试全部通道
    if (url.pathname === '/test') {
      const name = env.NODE_NAME || 'NAS';
      const r = await push(env, `${name} 测试通知`, '这是一条来自 Cloudflare Worker 的测试推送。');
      return new Response(r.ok ? `sent:${r.channel}` : `failed:${r.reason}`, {
        status: r.ok ? 200 : 500,
      });
    }

    return new Response('netwatch worker v3\n', { status: 200 });
  },

  async scheduled(event, env) {
    const lastStr = await env.HEARTBEAT_KV.get(KEY_LAST);
    if (!lastStr) {
      console.log('no heartbeat yet, skip');
      return;
    }

    const now = Date.now();
    const gap = now - parseInt(lastStr, 10);
    const alertAfter = parseInt(env.ALERT_AFTER_SEC || '600', 10) * 1000;
    const alerting = (await env.HEARTBEAT_KV.get(KEY_ALERTING)) === 'true';
    const name = env.NODE_NAME || 'NAS';

    console.log(`scheduled: gap=${Math.round(gap / 1000)}s alerting=${alerting}`);

    if (gap > alertAfter && !alerting) {
      const r = await push(
        env,
        `${name} 疑似断网`,
        `已 ${fmtGap(gap)} 没有收到心跳。可能原因：宽带断开、光猫或路由器断电、NAS 关机、IPv6 前缀变化。`
      );
      if (r.ok) await env.HEARTBEAT_KV.put(KEY_ALERTING, 'true');
    }
  },
};

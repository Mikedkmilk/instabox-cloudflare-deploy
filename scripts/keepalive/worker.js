/**
 * InstaBox 保活 Worker（Cloudflare cron）
 *
 * 作用：定期续租 activity lease + 定期跑一次真实 exec，
 *      让 InstaBox 机器既不被空闲挂起（30 分钟），又能拿到 max-run 延长。
 *
 * 为什么用 activity lease 而不是改 autoSuspendAfterSeconds：
 *   免费套餐把空闲挂起阈值锁死在 1800 秒（fixedAutoSuspendSeconds），
 *   PATCH autoSuspendAfterSeconds 会被服务端静默忽略（返回 200 但值不变），
 *   `instabox auto-suspend <box> 0` 也无效。activity lease 是官方唯一能用的口子。
 *
 * 为什么除了续租还要跑 exec（免费档的 max-run 动态延长）：
 *   官方文档《Machines → Auto-pause and max-run》写得很明确：
 *     - 免费档每一轮 run 从 2 小时窗口起步；`instabox get` 报的就是这个当前上限。
 *     - deadline 前 5 分钟，服务端检查前 30 个完整分钟里的「真实工作量」：
 *         ≥ 5 个不同的工作分钟 → deadline 延长 2 小时
 *         1–4 个              → 延长 30 分钟
 *         0 个                → 到点直接暂停
 *     - 计入工作量的：exec、文件请求、app 请求、终端/SSH 流量、访客活动。
 *     - **不计入工作量的：续租 keepalive lease、请求唤醒。**
 *   所以只续租只能挡住「空闲挂起」，拿不到 max-run 延长，机器照样会在
 *   当前窗口结束时被 max-run 暂停。而且免费档连续撞 max-run 的冷却期会
 *   逐级变长：第 1 次 5–20 分钟 → 第 2 次 60–75 分钟 → 第 3 次起 120–135 分钟。
 *
 *   cron 每 3 分钟跑一次 exec，任意 30 分钟窗口内就有 10 个不同的工作分钟，
 *   ≥ 5 → 每轮都能延长 2 小时，一路延到 8 小时上限。
 *
 * 关键细节（都是实测踩出来的）：
 *   1. lease 端点只认机器 ID（m_xxx），用机器名会 404 machine not found。
 *   2. 续租 TTL 必须大于 cron 间隔，否则两次之间出现空窗。
 *      默认 TTL=900s，cron 每 3 分钟（180s）一次。
 *   3. 机器被平台挂起/停掉时续租返回 409 machine_not_running，
 *      需要先 resume（stopped 用 start 兜底），等 running 后再续租。
 *      resume/start 是 mutating POST，必须带 Idempotency-Key。
 *   4. 撞上运行上限后有冷却期，返回 409 machine_cooldown，
 *      这期间任何唤醒都被拒，本轮跳过即可，不要硬撞。
 *   5. exec 不需要 Idempotency-Key（它不是幂等的，重试会重跑命令）。
 *
 * 环境变量（Secrets 与 Text）：
 *   INSTABOX_API_KEY   Secret  ibk_ 开头的 API key（需要 machines:write）
 *   INSTABOX_MACHINE   Text    机器 ID（m_xxx）；留空 = 该 key 名下全部机器
 *   INSTABOX_TTL       Text    租约秒数，默认 900，范围 30–3600
 *   INSTABOX_EXEC_CMD  Text    每轮跑的命令，默认体检隧道连接器
 *   TOKEN              Secret   访问本 Worker 的口令；不设则任何人可触发
 */

const API = "https://api.instabox.sh";
const DEFAULT_TTL = 900; // 租约时长，最大 3600
const LEASE_NAME = "keepalive";
// 默认体检隧道连接器（scripts/setup-tunnel.sh 装的就是 cloudflared 服务）。
// 换成自己的健康检查命令也行，例如 curl 应用端口；只要是一条真命令即可。
const DEFAULT_EXEC_CMD = "systemctl is-active cloudflared 2>/dev/null; true";

/** 统一的 API 调用 */
async function call(key, method, path, body, extraHeaders) {
  const headers = { "X-API-Key": key };
  if (body !== undefined) headers["Content-Type"] = "application/json";
  if (extraHeaders) Object.assign(headers, extraHeaders);
  const res = await fetch(API + path, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await res.text();
  let json = null;
  try {
    json = text ? JSON.parse(text) : null;
  } catch {
    /* 非 JSON 响应，按原文处理 */
  }
  return { ok: res.ok, status: res.status, json, text };
}

/** 取错误码（官方约定：branch on error.code） */
function errCode(r) {
  return r.json?.error?.code || "";
}

/** 取建议重试秒数 */
function retryAfter(r) {
  return r.json?.error?.retryAfterSeconds || 0;
}

/** TTL：env 优先，非法值回落到默认 */
function ttlOf(env) {
  const n = parseInt((env.INSTABOX_TTL || "").trim(), 10);
  if (!Number.isFinite(n) || n < 30 || n > 3600) return DEFAULT_TTL;
  return n;
}

/** 每轮跑什么命令（env 优先） */
function execCmdOf(env) {
  const c = (env.INSTABOX_EXEC_CMD || "").trim();
  return c || DEFAULT_EXEC_CMD;
}

/** 列出该 key 名下的机器 */
async function listMachines(key, wanted) {
  if (wanted) {
    const r = await call(key, "GET", `/v1/machines/${encodeURIComponent(wanted)}`);
    if (!r.ok) return { error: `查不到机器 ${wanted}（${errCode(r) || r.status}）`, list: [] };
    return { error: null, list: [r.json] };
  }
  const r = await call(key, "GET", "/v1/machines");
  if (!r.ok) return { error: `列机器失败（${errCode(r) || r.status}）`, list: [] };
  return { error: null, list: r.json?.machines || [] };
}

/** 查机器当前状态 */
async function stateOf(key, id) {
  const r = await call(key, "GET", `/v1/machines/${id}`);
  return r.ok ? r.json?.state || "" : "";
}

/**
 * 唤醒机器：resume 优先，stopped 用 start 兜底；等 running
 * 注意 resume/start 需要 Idempotency-Key
 */
async function wake(key, id) {
  for (const action of ["resume", "start"]) {
    const r = await call(key, "POST", `/v1/machines/${id}/${action}`, undefined, {
      "Idempotency-Key": crypto.randomUUID(),
    });
    if (r.ok) {
      for (let i = 0; i < 12; i++) {
        await new Promise((d) => setTimeout(d, 5000));
        if ((await stateOf(key, id)) === "running") return true;
      }
    }
  }
  return false;
}

/**
 * 做一次真实 exec —— 免费档的 max-run 动态延长只认「真实工作」。
 *
 * 官方文档明确写着：Renewing a keepalive lease or requesting a wake
 * does not earn an extension。所以光续租拿不到 max-run 延长，
 * 机器照样会在当前窗口结束时被 max-run 暂停（且连续撞的冷却期
 * 5–20 → 60–75 → 120–135 分钟逐级变长）。
 *
 * 每 3 分钟跑一次，任意 30 分钟窗口内就有 10 个不同的工作分钟，
 * ≥ 5 → 每次都能延长 2 小时。
 *
 * 顺带把关键服务的状态读回来，一举两得。
 */
async function realWork(key, id, cmd) {
  const r = await call(key, "POST", `/v1/machines/${id}/exec`, {
    cmd,
    timeoutSeconds: 20,
    noHistory: true,
  });
  if (!r.ok) {
    return { ok: false, detail: `exec 失败 HTTP ${r.status} ${errCode(r)}` };
  }
  const out = String(r.json?.stdout || "").trim().replace(/\s+/g, "/");
  return { ok: true, detail: `exec ok（${out || "无输出"}）` };
}

/** 续租一台机器，返回 { ok, machine, detail } */
async function keepaliveOne(key, machine, ttl, execCmd) {
  const id = machine.id;
  const name = machine.name || id;

  let r = await call(key, "PUT", `/v1/machines/${id}/activity-leases/${LEASE_NAME}`, {
    ttlSeconds: ttl,
  });

  if (r.ok) {
    const w = await realWork(key, id, execCmd);
    return {
      ok: w.ok,
      machine: name,
      detail: w.ok ? `续租成功，到期 ${r.json?.expiresAt}；${w.detail}` : `续租成功但 ${w.detail}`,
    };
  }

  const code = errCode(r);

  if (code === "machine_not_running") {
    // 机器被平台挂起或停掉了，光续租是空转 —— 先唤醒再续
    const woke = await wake(key, id);
    if (!woke) return { ok: false, machine: name, detail: "唤醒失败（仍在冷却或启动中）" };

    await new Promise((d) => setTimeout(d, 5000));
    r = await call(key, "PUT", `/v1/machines/${id}/activity-leases/${LEASE_NAME}`, {
      ttlSeconds: ttl,
    });
    if (!r.ok) {
      return { ok: false, machine: name, detail: `唤醒后续租失败（${errCode(r) || r.status}）` };
    }
    const w = await realWork(key, id, execCmd);
    return {
      ok: w.ok,
      machine: name,
      detail: w.ok
        ? `唤醒后续租成功，到期 ${r.json?.expiresAt}；${w.detail}`
        : `唤醒后续租成功但 ${w.detail}`,
    };
  }

  if (code === "machine_cooldown") {
    // 撞上运行上限的冷却期，这期间任何唤醒都被拒 —— 本轮跳过，不硬撞
    return {
      ok: false,
      machine: name,
      detail: `处于运行上限冷却期，约 ${retryAfter(r)} 秒后可唤醒，本轮跳过`,
      cooldown: true,
    };
  }

  return {
    ok: false,
    machine: name,
    detail: `续租失败 HTTP ${r.status} ${code}：${(r.text || "").slice(0, 160)}`,
  };
}

/** 执行一轮保活 */
async function runKeepalive(env) {
  const key = (env.INSTABOX_API_KEY || "").trim();
  if (!key) {
    return { ok: false, at: new Date().toISOString(), error: "未配置 INSTABOX_API_KEY", results: [] };
  }

  const wanted = (env.INSTABOX_MACHINE || "").trim();
  const { error, list } = await listMachines(key, wanted);
  if (error) {
    return { ok: false, at: new Date().toISOString(), error, results: [] };
  }
  if (!list.length) {
    return { ok: false, at: new Date().toISOString(), error: "这台 key 名下没有机器", results: [] };
  }

  const ttl = ttlOf(env);
  const execCmd = execCmdOf(env);
  const results = [];
  for (const m of list) {
    try {
      results.push(await keepaliveOne(key, m, ttl, execCmd));
    } catch (e) {
      results.push({ ok: false, machine: m.name || m.id, detail: `异常：${e.message}` });
    }
  }

  // 全部成功才算成功；冷却期不算失败（那是被动的等待）
  const hardFail = results.filter((r) => !r.ok && !r.cooldown);
  return {
    ok: hardFail.length === 0,
    at: new Date().toISOString(),
    count: results.length,
    ttl,
    results,
  };
}

/** 查各机器状态（不续租） */
async function runStatus(env) {
  const key = (env.INSTABOX_API_KEY || "").trim();
  if (!key) return { ok: false, error: "未配置 INSTABOX_API_KEY", results: [] };

  const wanted = (env.INSTABOX_MACHINE || "").trim();
  const { error, list } = await listMachines(key, wanted);
  if (error) return { ok: false, error, results: [] };

  const results = [];
  for (const m of list) {
    const r = await call(key, "GET", `/v1/machines/${m.id}`);
    results.push(
      r.ok
        ? {
            machine: m.name || m.id,
            id: m.id,
            state: r.json?.state,
            autoSuspendAfterSeconds: r.json?.autoSuspendAfterSeconds,
            maxRunMinutes: r.json?.maxRunMinutes,
            runStartedAt: r.json?.runStartedAt || null,
            cooldownUntil: r.json?.cooldownUntil || null,
            storage: r.json?.storage ? `${r.json.storage.sizeGiB}GiB` : null,
          }
        : { machine: m.name || m.id, error: `HTTP ${r.status}` }
    );
  }
  return { ok: true, at: new Date().toISOString(), results };
}

function reply(body, status, asText) {
  if (asText) {
    const lines = [`ok=${body.ok}`, `at=${body.at || new Date().toISOString()}`];
    if (body.error) lines.push(`error=${body.error}`);
    for (const r of body.results || []) {
      lines.push(`${r.ok === false ? "FAIL" : "ok  "} ${r.machine} ${r.detail || r.state || ""}`);
    }
    return new Response(lines.join("\n") + "\n", {
      status,
      headers: { "Content-Type": "text/plain; charset=utf-8" },
    });
  }
  return new Response(JSON.stringify(body, null, 2), {
    status,
    headers: { "Content-Type": "application/json; charset=utf-8" },
  });
}

export default {
  /** Cron 触发：按 cron 间隔续租一次 */
  async scheduled(event, env) {
    const out = await runKeepalive(env);
    if (out.ok) {
      console.log("instabox-keepalive:", JSON.stringify(out));
    } else {
      console.error("instabox-keepalive:", JSON.stringify(out));
    }
  },

  /** HTTP 触发：手动续租 / 查状态 */
  async fetch(request, env) {
    const url = new URL(request.url);
    const asText = url.searchParams.get("format") === "text";
    const route = url.pathname.replace(/\/+$/, "") || "/";

    // 设了 TOKEN 就必须带，否则任何人知道域名就能触发
    if (env.TOKEN && url.searchParams.get("token") !== env.TOKEN) {
      return reply({ ok: false, error: "token 不对" }, 401, asText);
    }

    if (route === "/" || route === "/keepalive") {
      const out = await runKeepalive(env);
      return reply(out, out.ok ? 200 : 502, asText);
    }
    if (route === "/status") {
      const out = await runStatus(env);
      return reply(out, out.ok ? 200 : 502, asText);
    }

    return reply(
      { ok: false, error: "用 / 续租、/status 查状态" },
      404,
      asText
    );
  },
};

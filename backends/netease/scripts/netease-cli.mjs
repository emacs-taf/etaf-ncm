#!/usr/bin/env node
// netease-cli.mjs —— 编排层：把命令翻译成取数/播放调用，并管理登录态等状态。
//
// 分工（每层可单独验证）：
//   netease-api.mjs  取数：直连接口，收参数、出 JSON，不认识状态目录
//   mpv-ctl.mjs      播放：常驻 mpv 的 IPC 桥
//   本文件           编排：组合上面两层，保存登录态与队列
//
// 为什么单独一层：编排原来只有 netease-music.sh 一份，而 bash 在 Windows 上
// 没有原生实现（`bash.exe' 是 WSL 启动器，读不了 Windows 路径）。编排放在
// Node 里，各平台都由 node.exe 直接执行，不需要任何 shell 参与。
//
// 与客户端（Emacs）的约定，和 netease-music.sh 相同：
//   成功：stdout 一行 JSON（--json）或一行结论，退出 0
//   失败：stderr 一行 {"error":CODE,"hint":TEXT}，退出 usage=2 auth=3 notfound=4 其它=5
import { execFile } from 'node:child_process';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const API = join(HERE, 'netease-api.mjs');
// 状态目录与 netease-music.sh 用同一套规则，两个入口永远看同一份登录态。
const STATE_DIR =
  process.env.NETEASE_MUSIC_STATE_DIR ||
  join(process.env.XDG_STATE_HOME || join(homedir(), '.local', 'state'), 'netease-music');
const CONFIG = join(STATE_DIR, 'config.json');
// 登录可能要等手机上的安全验证，比普通取数宽松得多。
const API_TIMEOUT = 300_000;

class CliError extends Error {
  constructor(code, hint) {
    super(hint);
    this.code = code;
    this.hint = hint;
  }
}

// 取数层是黑盒命令：成功给一行 JSON，失败给一行错误 JSON 和退出码。这里只
// 转发，让调用方拿到原样的 error/hint 与退出码。
function api(args, cookie) {
  const env = { ...process.env };
  if (cookie) env.NETEASE_COOKIE = cookie;
  return new Promise((resolve, reject) => {
    execFile(process.execPath, [API, ...args], { env, timeout: API_TIMEOUT, maxBuffer: 8 << 20 },
      (error, stdout, stderr) => {
        if (error) {
          const report = lastJson(stderr);
          reject(new CliError(report?.error || 'external', report?.hint || stderr.trim() || String(error)));
          return;
        }
        const data = lastJson(stdout);
        if (data) resolve(data);
        else reject(new CliError('internal', '取数层没有返回 JSON：' + stdout.trim().slice(0, 200)));
      });
  });
}

// 进度行也会写到 stderr，所以要找最后那一行 JSON。
function lastJson(text) {
  for (const line of String(text).trim().split('\n').reverse()) {
    try {
      return JSON.parse(line);
    } catch {
      continue;
    }
  }
  return null;
}

async function readConfig() {
  try {
    return JSON.parse(await readFile(CONFIG, 'utf8'));
  } catch {
    return {};
  }
}

// 只并进要改的键，其余原样留着：配置里还有音质、did 这些别的入口写的内容。
async function writeConfig(patch) {
  const config = { ...(await readConfig()), ...patch };
  await mkdir(STATE_DIR, { recursive: true });
  await writeFile(CONFIG, JSON.stringify(config, null, 2), 'utf8');
  return config;
}

const maskPhone = (phone) => String(phone).replace(/^(\d{3})\d*(\d{4})$/, '$1****$2');

function isoNow() {
  const now = new Date();
  const pad = (value, width = 2) => String(Math.abs(value)).padStart(width, '0');
  const offset = -now.getTimezoneOffset();
  return `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}`
    + `T${pad(now.getHours())}:${pad(now.getMinutes())}:${pad(now.getSeconds())}`
    + `${offset < 0 ? '-' : '+'}${pad(Math.trunc(offset / 60))}${pad(offset % 60)}`;
}

function emit({ conclusion, ...fields }) {
  const payload = { ok: true, conclusion, ...fields, as_of: isoNow() };
  console.log(jsonOut ? JSON.stringify(payload) : conclusion);
}

// 短信登录分两步，和命令行一致：先发码，再拿码换 cookie。
async function login(phone, code) {
  if (!/^\d{5,20}$/.test(phone || '')) {
    throw new CliError('usage', '短信登录要先给手机号：login --sms <手机号>');
  }
  if (!code) {
    await api(['sms-send', phone]);
    await writeConfig({ phone });
    const masked = maskPhone(phone);
    return { conclusion: `验证码已发到 ${masked}：收到后输入验证码完成登录`, phone: masked };
  }
  if (!/^\d{3,8}$/.test(code)) throw new CliError('usage', '验证码应是 3-8 位数字');
  const { cookie } = await api(['sms-login', phone, code]);
  // 先落盘：接口已经给了登录态，后面取昵称失败也不该把这次登录丢掉。
  await writeConfig({ cookie, phone });
  const session = await api(['session'], cookie);
  return { conclusion: `登录成功：${session.nick || maskPhone(phone)}`, nick: session.nick, uid: session.uid };
}

const COMMANDS = {
  // login --sms <手机号> [--sms-code <验证码>]
  login: ({ args: [phone], flags }) => login(phone, flags.get('--sms-code')),
};

// 开关不取值（--sms 只是让手机号当位置参数），带值的旗标按 `--name value` 收。
function parse(argv) {
  const positional = [];
  const flags = new Map();
  let json = false;
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === '--json') json = true;
    else if (arg === '--sms') continue;
    else if (arg.startsWith('--')) flags.set(arg, argv[++i]);
    else positional.push(arg);
  }
  const [command, ...args] = positional;
  return { command, args, flags, json };
}

let jsonOut = false;

function fail(error) {
  const code = error.code || 'internal';
  console.error(JSON.stringify({ error: code, hint: error.hint || String(error) }));
  process.exit(code === 'usage' ? 2 : code === 'auth' ? 3 : code === 'notfound' ? 4 : 5);
}

async function main() {
  const request = parse(process.argv.slice(2));
  jsonOut = request.json;
  const handler = COMMANDS[request.command];
  if (!handler) {
    throw new CliError('usage',
      `未知命令 ${request.command || '(空)'}；可用：${Object.keys(COMMANDS).join(' ')}`);
  }
  emit(await handler(request));
}

try {
  await main();
} catch (error) {
  fail(error);
}

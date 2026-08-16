// KernelSU-Next WebUI：Manager 通过 addJavascriptInterface(WebViewInterface, "ksu") 注入全局 window.ksu
// 真实 API（KernelSU-Next dev 分支 WebViewInterface.kt / WebUIActivity.kt）：
//   ksu.moduleInfo()            -> JSON 字符串，需 JSON.parse，含 id / moduleDir / name / version / author ...
//   ksu.exec(cmd)               -> 同步返回 stdout 字符串（无 errno/stdout 字段）
//   ksu.exec(cmd, options, cb)  -> 回调式，cb(code, stdout, stderr)；options 为 JSON 字符串 {cwd,env} 或 null
//   ksu.toast(msg)              -> 显示系统 Toast
const ksu = window.ksu;
const toast = (m) => (ksu && ksu.toast) ? ksu.toast(m) : console.log('[toast]', m);

// 统一封装为 Promise，兼容三种 exec 形态：同步版(1参) / 回调版(2参) / 回调+options版(3参)
function ksuExec(cmd) {
  return new Promise((resolve, reject) => {
    if (!ksu) { reject(new Error('ksu API 不可用')); return; }
    const cbName = '__ksuCb_' + Date.now() + '_' + Math.floor(Math.random() * 1e6);
    window[cbName] = (code, stdout, stderr) =>
      resolve({ errno: (code | 0), stdout: stdout || '', stderr: stderr || '' });
    try {
      const n = ksu.exec.length;
      if (n >= 3) ksu.exec(cmd, null, cbName);
      else if (n === 2) ksu.exec(cmd, cbName);
      else {
        delete window[cbName];
        resolve({ errno: 0, stdout: String(ksu.exec(cmd) || ''), stderr: '' });
      }
    } catch (e) {
      try { delete window[cbName]; } catch (_) { /* noop */ }
      reject(e);
    }
  });
}

const MOD_ID = (() => {
  try {
    const info = JSON.parse(ksu.moduleInfo());
    return info.id || (info.moduleDir ? info.moduleDir.split('/').pop() : 'swab_protect');
  } catch (_) {
    return 'swab_protect';
  }
})();
const SWAB = `/data/adb/modules/${MOD_ID}/swab.sh`;
const LOG = '/data/local/tmp/swab_protect.log';

const statusEl = document.getElementById('status-output');
const diagEl = document.getElementById('diag-output');
const modal = document.getElementById('modal');
const modalTitle = document.getElementById('modal-title');
const modalText = document.getElementById('modal-text');

document.getElementById('module-badge').textContent = MOD_ID;

// ---------- 动作定义 ----------
const ACTIONS = {
  refresh:   { args: '-s',        out: 'status' },
  'switch-a':{ args: 'a',         out: 'status', confirm: ['切换槽位', '将切换到 A 槽，重启后生效。\n切换前会自动备份当前 boot_ctrl，请确保电量充足。'] },
  'switch-b':{ args: 'b',         out: 'status', confirm: ['切换槽位', '将切换到 B 槽，重启后生效。\n切换前会自动备份当前 boot_ctrl，请确保电量充足。'] },
  'switch-o':{ args: '-o',        out: 'status', confirm: ['切换对位槽', '将以当前运行槽为基准切换到对位槽（A ⇄ B），重启后生效。\n切换前会自动备份当前 boot_ctrl。'] },
  'switch-a-r':{ args: 'a -r',    out: 'status', confirm: ['切换并重启', '将切换到 A 槽并立即重启设备！\n请先保存好手头工作、确保电量充足，确认后设备将重启。'] },
  'switch-b-r':{ args: 'b -r',    out: 'status', confirm: ['切换并重启', '将切换到 B 槽并立即重启设备！\n请先保存好手头工作、确保电量充足，确认后设备将重启。'] },
  'active-a':{ args: '-a a',      out: 'status', confirm: ['设置 A 为 active', '将直接改写 boot_ctrl 结构体：A 槽 priority=15、tries=7，其他 priority≥15 的槽降为 14。'] },
  'active-b':{ args: '-a b',      out: 'status', confirm: ['设置 B 为 active', '将直接改写 boot_ctrl 结构体：B 槽 priority=15、tries=7，其他 priority≥15 的槽降为 14。'] },
  'protect-a':{ args: '-p a',     out: 'status', confirm: ['A 槽保护模式', '将 A 槽置为保护模式：successful_boot=0、tries_remaining=6。引导失败时 preloader 会自动回退另一槽，防变砖兜底。'] },
  'protect-b':{ args: '-p b',     out: 'status', confirm: ['B 槽保护模式', '将 B 槽置为保护模式：successful_boot=0、tries_remaining=6。引导失败时 preloader 会自动回退另一槽，防变砖兜底。'] },
  dump:      { args: '-d',        out: 'diag' },
  log:       { args: 'log',       out: 'diag', custom: true },
};

// ---------- 工具 ----------
function pickOutput(name) {
  return name === 'diag' ? diagEl : statusEl;
}

async function runCmd(action) {
  const target = pickOutput(action.out);

  if (action.args === 'log') {
    // 读取开机保护日志（service.sh 每次开机追加）
    const cmd = `tail -n 100 ${LOG}`;
    target.textContent = `$ ${cmd}\n\n运行中…`;
    try {
      const { errno, stdout, stderr } = await ksuExec(cmd);
      target.textContent = `$ ${cmd}\n\n${errno === 0 ? stdout : `[exit ${errno}] ${stderr || '日志不存在或不可读'}`}`;
      toast(errno === 0 ? '已读取日志' : '读取日志失败');
    } catch (e) {
      target.textContent = `$ ${cmd}\n\n执行出错: ${e.message}`;
      toast('执行出错');
    }
    return;
  }

  const cmd = `sh ${SWAB} ${action.args}`;
  target.textContent = `$ ${cmd}\n\n运行中…`;
  setBusy(true);
  try {
    const { errno, stdout, stderr } = await ksuExec(cmd);
    const txt = `$ ${cmd}\n\n${stdout}${stderr ? `\n\n[stderr]\n${stderr}` : ''}\n\n[exit code: ${errno}]`;
    target.textContent = txt;
    target.scrollTop = target.scrollHeight;
    toast(errno === 0 ? '执行成功' : '执行失败，请查看输出');
  } catch (e) {
    target.textContent = `$ ${cmd}\n\n执行出错: ${e.message}`;
    toast('执行出错');
  } finally {
    setBusy(false);
  }
}

function setBusy(busy) {
  document.querySelectorAll('[data-action]').forEach((btn) => {
    btn.disabled = busy;
  });
}

// ---------- 确认弹窗 ----------
function askConfirm(title, text) {
  return new Promise((resolve) => {
    modalTitle.textContent = title;
    modalText.textContent = text;
    modal.classList.remove('hidden');

    const ok = () => { cleanup(); resolve(true); };
    const cancel = () => { cleanup(); resolve(false); };
    const cleanup = () => {
      modal.classList.add('hidden');
      document.getElementById('modal-ok').removeEventListener('click', ok);
      document.getElementById('modal-cancel').removeEventListener('click', cancel);
    };
    document.getElementById('modal-ok').addEventListener('click', ok);
    document.getElementById('modal-cancel').addEventListener('click', cancel);
  });
}

// ---------- 事件绑定 ----------
document.querySelectorAll('[data-action]').forEach((btn) => {
  btn.addEventListener('click', async () => {
    const action = ACTIONS[btn.dataset.action];
    if (!action) return;
    if (action.confirm) {
      const ok = await askConfirm(action.confirm[0], action.confirm[1]);
      if (!ok) return;
    }
    await runCmd(action);
  });
});

// ---------- 初始加载状态 ----------
if (ksu) {
  runCmd(ACTIONS.refresh);
} else {
  document.getElementById('status-output').textContent =
    '错误：未检测到 KernelSU API (window.ksu)。\n此界面需在 KernelSU Manager 的模块详情页中打开。';
}

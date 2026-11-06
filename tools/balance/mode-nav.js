/* SPDX-License-Identifier: AGPL-3.0-only */
// 在同一浏览器标签里往返两个游戏时，保留下班当前链接的配置和对照实验。
const offWorkLink = document.querySelector('.mode-nav a[href="/off-work/"]');
if (offWorkLink) {
  try {
    const key = 'niuma.off-work.comparison';
    if (offWorkLink.hasAttribute('aria-current')) {
      const query = new URLSearchParams(location.search);
      const saved = new URLSearchParams();
      for (const parameter of ['cards','left','right','run']) {
        const value = query.get(parameter);
        const format = parameter === 'cards' ? /^cards_[a-f0-9]{64}$/ : /^[a-f0-9]{32}$/;
        if (value && format.test(value)) saved.set(parameter, value);
      }
      sessionStorage.setItem(key, saved.toString());
    } else {
      const query = sessionStorage.getItem(key);
      if (query) offWorkLink.search = query;
    }
  } catch {
    // 浏览器禁用会话存储时，链接仍直接打开工作台。
  }
}

// A live page owns a connection to the launcher. Closing the final tab lets
// the foreground service exit after outstanding simulations have finished.
let workbenchSession;
function connectWorkbenchSession() {
  workbenchSession = new EventSource('/api/session');
}
window.addEventListener('pagehide', () => workbenchSession?.close());
window.addEventListener('pageshow', connectWorkbenchSession);

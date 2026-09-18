// 共用：导航滚动后加分隔线
(() => {
  const nav = document.getElementById('nav');
  if (!nav) return;
  const nights = [...document.querySelectorAll('.night')];
  const on = () => {
    nav.classList.toggle('is-scrolled', window.scrollY > 8);
    const y = nav.offsetHeight / 2;
    nav.classList.toggle('is-dark', nights.some((n) => {
      const r = n.getBoundingClientRect();
      return r.top <= y && r.bottom >= y;
    }));
  };
  on();
  window.addEventListener('scroll', on, { passive: true });
})();

// 语言切换：标出当前语言，记住用户的选择（和旧官网同一个 tf_lang）
(() => {
  const sw = document.getElementById('langsw');
  if (!sw) return;
  const cur = document.documentElement.dataset.lang;
  sw.querySelectorAll('a').forEach((a) => {
    if (a.dataset.l === cur) a.classList.add('on');
    a.addEventListener('click', () => { try { localStorage.setItem('tf_lang', a.dataset.l); } catch (e) {} });
  });
})();

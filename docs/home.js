(() => {
  const $ = (s, r = document) => r.querySelector(s);
  const $$ = (s, r = document) => [...r.querySelectorAll(s)];
  const reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  // 各语言页面在 window.TF_HOME 里提供演示文字
  const T = window.TF_HOME;

  /* ---------- 首屏标题：默认是乱的，鼠标移进来变干净，移开又乱 ---------- */
  const thesis = $('#thesis');
  // 复制一份看不见的「乱」版本撑住标题大小，鼠标感应范围就固定在「乱」的时候字占的那一块
  const live = document.createElement('span');
  live.className = 'thesis-live';
  const ghost = document.createElement('span');
  ghost.className = 'thesis-ghost';
  $$('.ln', thesis).forEach((ln) => {
    const copy = ln.cloneNode(true);
    $$('.fl', copy).forEach((f) => { f.className = 'gfl'; f.removeAttribute('style'); });
    $$('.caret', copy).forEach((c) => c.remove());
    ghost.append(copy);
    live.append(ln);
  });
  thesis.append(ghost, live);
  const setClean = (on) => thesis.classList.toggle('is-clean', on);
  if (window.matchMedia('(hover: hover) and (pointer: fine)').matches) {
    thesis.addEventListener('mouseenter', () => setClean(true));
    thesis.addEventListener('mouseleave', () => setClean(false));
  } else {
    // 手机、平板没有鼠标：自动来回切，点一下也能切
    let timer = 0;
    const loop = (clean) => {
      setClean(clean);
      timer = setTimeout(() => loop(!clean), clean ? 3000 : 2200);
    };
    if (!reduce) timer = setTimeout(() => loop(true), 1500);
    thesis.addEventListener('click', () => {
      clearTimeout(timer);
      const clean = !thesis.classList.contains('is-clean');
      setClean(clean);
      if (!reduce) timer = setTimeout(() => loop(!clean), 4000);
    });
  }

  /* ---------- 演示舞台 ---------- */
  const screen = $('#screen');
  const cur = $('.cursor', screen);
  const cap = $('.capsule', screen);
  const capLbl = $('.lbl', cap);
  const chip = $('.chip', screen);
  const chipText = $('.chip-text', screen);
  const tabs = $$('.stab');
  const DUR = [9800, 9600, 9600];
  let run = 0;

  const sleep = (ms, id) => new Promise((ok, no) =>
    setTimeout(() => (id === run ? ok() : no('cancel')), reduce ? 0 : ms));

  const capState = (cls = '', label = '') => {
    cap.className = 'capsule ' + cls;
    capLbl.textContent = label;
  };

  const pointAt = (el, fx = 0.5, fy = 0.5) => {
    const s = screen.getBoundingClientRect();
    const r = el.getBoundingClientRect();
    cur.style.left = ((r.left - s.left + r.width * fx) / s.width) * 100 + '%';
    cur.style.top = ((r.top - s.top + r.height * fy) / s.height) * 100 + '%';
  };

  const speak = async (words, id, gap = 260) => {
    chipText.textContent = '';
    chip.classList.remove('is-marked', 'is-gone');
    chip.classList.add('is-on');
    for (const w of words) {
      const sp = document.createElement('span');
      sp.className = 'tw' + (w.f ? ' fl' : '') + (w.cmd ? ' cmd' : '');
      sp.textContent = w.t;
      chipText.append(sp);
      await sleep(gap, id);
    }
  };

  const type = async (el, text, id, speed) => {
    if (reduce) { el.textContent = text; return; }
    for (let i = 1; i <= text.length; i++) {
      el.textContent = text.slice(0, i);
      await sleep(speed, id);
    }
  };

  const send = (sc) => {
    const txt = $('.w-input-text', sc);
    const b = document.createElement('div');
    b.className = 'w-msg me';
    b.textContent = txt.textContent;
    $('.w-log', sc).append(b);
    txt.textContent = '';
    $('.w-input', sc).classList.remove('is-focus');
  };

  const resetAll = () => {
    $$('.scene', screen).forEach((sc) => {
      sc.classList.remove('is-on');
      $$('.w-msg.me', sc).forEach((m) => m.remove());
      $$('.w-input-text', sc).forEach((t) => (t.textContent = ''));
      $$('.w-input', sc).forEach((t) => t.classList.remove('is-focus'));
    });
    $('.panel', screen).classList.remove('is-on');
    $('.panel-a', screen).textContent = '';
    chip.classList.remove('is-on', 'is-marked', 'is-gone');
    capState();
    cur.classList.remove('is-down', 'ask');
  };

  const scenes = [
    // 一：按住说话
    async (id) => {
      const sc = $('[data-scene="talk"]', screen);
      const input = $('.w-input', sc);
      sc.classList.add('is-on');
      cur.style.left = '82%'; cur.style.top = '36%';
      await sleep(600, id);
      pointAt(input, 0.46, 0.5);
      await sleep(850, id);
      cur.classList.add('is-down'); input.classList.add('is-focus');
      await sleep(320, id);
      capState('is-on rec');
      await sleep(260, id);
      await speak(T.talk.words, id, 300);
      await sleep(450, id);
      cur.classList.remove('is-down');
      capState('is-on busy', T.talk.busy);
      chip.classList.add('is-marked');
      await sleep(600, id);
      chip.classList.add('is-gone');
      await sleep(700, id);
      chip.classList.remove('is-on');
      capState();
      await type($('.w-input-text', sc), T.talk.out, id, T.talk.speed || 45);
      await sleep(900, id);
      send(sc);
      await sleep(2100, id);
    },
    // 二：问 AI
    async (id) => {
      const sc = $('[data-scene="ask"]', screen);
      sc.classList.add('is-on');
      cur.classList.add('ask');
      cur.style.left = '40%'; cur.style.top = '88%';
      await sleep(600, id);
      pointAt($('.w-blank', sc), 0.62, 0.45);
      await sleep(850, id);
      cur.classList.add('is-down');
      await sleep(320, id);
      capState('is-on rec ask');
      await sleep(260, id);
      await speak(T.ask.words, id, 320);
      await sleep(450, id);
      cur.classList.remove('is-down');
      capState('is-on busy ask', T.ask.busy);
      await sleep(900, id);
      chip.classList.remove('is-on');
      capState();
      $('.panel', sc).classList.add('is-on');
      await sleep(500, id);
      await type($('.panel-a', sc), T.ask.answer, id, T.ask.speed || 26);
      await sleep(2700, id);
    },
    // 三：句尾说「用英文」
    async (id) => {
      const sc = $('[data-scene="trans"]', screen);
      const input = $('.w-input', sc);
      sc.classList.add('is-on');
      cur.style.left = '84%'; cur.style.top = '30%';
      await sleep(600, id);
      pointAt(input, 0.4, 0.5);
      await sleep(850, id);
      cur.classList.add('is-down'); input.classList.add('is-focus');
      await sleep(320, id);
      capState('is-on rec');
      await sleep(260, id);
      await speak(T.trans.words, id, 380);
      await sleep(550, id);
      cur.classList.remove('is-down');
      capState('is-on lang', T.trans.tag);
      await sleep(900, id);
      chip.classList.remove('is-on');
      await type($('.w-input-text', sc), T.trans.out, id, T.trans.speed || 22);
      capState();
      await sleep(900, id);
      send(sc);
      await sleep(2100, id);
    },
  ];

  let raf = 0;
  const setTab = (i) => {
    tabs.forEach((t, k) => {
      t.classList.toggle('is-on', k === i);
      t.setAttribute('aria-selected', k === i);
      $('.bar', t).style.width = '0';
    });
    cancelAnimationFrame(raf);
    if (reduce) { $('.bar', tabs[i]).style.width = '100%'; return; }
    const t0 = performance.now();
    const bar = $('.bar', tabs[i]);
    const tick = (now) => {
      bar.style.width = Math.min(1, (now - t0) / DUR[i]) * 100 + '%';
      if (now - t0 < DUR[i]) raf = requestAnimationFrame(tick);
    };
    raf = requestAnimationFrame(tick);
  };

  const play = async (i) => {
    const id = ++run;
    resetAll();
    setTab(i);
    try {
      await scenes[i](id);
    } catch (e) {
      if (e !== 'cancel') console.error(e);
      return;
    }
    if (id === run && !reduce) play((i + 1) % scenes.length);
  };

  tabs.forEach((t) => t.addEventListener('click', () => play(+t.dataset.i)));

  let started = false;
  new IntersectionObserver((es) => {
    if (!started && es.some((e) => e.isIntersecting)) { started = true; play(0); }
  }, { threshold: 0.25 }).observe(screen);

  /* ---------- 真实效果 ---------- */
  const board = $('#board');
  const data = [...$('#case-data').content.children];
  const ctabs = $$('.ctab');
  let caseTimer = [];
  const showCase = (i) => {
    caseTimer.forEach(clearTimeout);
    ctabs.forEach((t, k) => t.setAttribute('aria-selected', k === i));
    const d = data[i];
    board.classList.remove('is-marked', 'is-done');
    $('.raw-text', board).innerHTML = $('.r', d).innerHTML;
    $('.clean-text', board).textContent = $('.c', d).textContent;
    $('.btags', board).innerHTML = d.dataset.tags.split(',').map((s) => `<span>${s}</span>`).join('');
    void board.offsetWidth;
    caseTimer = [
      setTimeout(() => board.classList.add('is-marked'), reduce ? 0 : 500),
      setTimeout(() => board.classList.add('is-done'), reduce ? 0 : 1300),
    ];
  };
  ctabs.forEach((t) => t.addEventListener('click', () => showCase(+t.dataset.case)));
  $('.raw-text', board).innerHTML = $('.r', data[0]).innerHTML;
  $('.clean-text', board).textContent = $('.c', data[0]).textContent;
  $('.btags', board).innerHTML = '<span>口误修正</span>';
  let caseSeen = false;
  new IntersectionObserver((es) => {
    if (!caseSeen && es.some((e) => e.isIntersecting)) { caseSeen = true; showCase(0); }
  }, { threshold: 0.4 }).observe(board);

  /* ---------- 句尾口令轮换（文字取自 App 自带的功能演示） ---------- */
  const roll = $('#roll');
  const said = $('#said');
  const outText = $('#outText');
  const langs = $$('#langs span');
  let li = 0;
  if (!reduce && T.roll && T.roll.length > 1) {
    setInterval(() => {
      li = (li + 1) % T.roll.length;
      const step = T.roll[li];
      roll.style.transform = `translateY(${-li * 1.7}em)`;
      outText.classList.add('is-swap');
      said.classList.add('is-swap');
      langs.forEach((el, k) => el.classList.toggle('is-on', k === step.lang));
      setTimeout(() => {
        outText.textContent = step.out;
        said.textContent = step.said;
        outText.classList.remove('is-swap');
        said.classList.remove('is-swap');
      }, 380);
    }, 2800);
  }

  /* ---------- 数据去向切换 ---------- */
  const route = $('#route');
  $$('.seg button', route).forEach((b) => b.addEventListener('click', () => {
    route.dataset.mode = b.dataset.mode;
    $$('.seg button', route).forEach((x) => x.setAttribute('aria-pressed', x === b));
  }));
})();

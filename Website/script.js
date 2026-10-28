const pageLanguage = document.documentElement.lang;
const currentURL = new URL(window.location.href);
const requestedLanguage = currentURL.searchParams.get('lang');
let savedLanguage;
try {
  savedLanguage = window.localStorage.getItem('beamly-language');
} catch {
  // Storage can be unavailable in private browsing or local file previews.
}
const preferredLanguage = ['ru', 'en'].includes(requestedLanguage)
  ? requestedLanguage
  : pageLanguage === 'ru' && savedLanguage === 'en' ? 'en' : pageLanguage;
if (preferredLanguage !== pageLanguage) {
  const destination = new URL(preferredLanguage === 'en' ? 'en.html' : 'index.html', currentURL);
  destination.search = currentURL.search;
  destination.hash = currentURL.hash;
  window.location.replace(destination.href);
}
for (const link of document.querySelectorAll('.language-link')) {
  link.addEventListener('click', () => {
    try {
      window.localStorage.setItem('beamly-language', link.getAttribute('data-language'));
    } catch {
      // The language links still work without storage.
    }
  });
}

const playbackText = pageLanguage === 'en'
  ? { pause: 'Pause the demo', resume: 'Resume the demo', playing: 'Playing on your TV', paused: 'Paused' }
  : { pause: 'Поставить демонстрацию на паузу', resume: 'Продолжить демонстрацию', playing: 'Воспроизводится на телевизоре', paused: 'На паузе' };
const playButton = document.querySelector('#demo-play');
playButton.addEventListener('click', () => {
  const playing = playButton.getAttribute('aria-pressed') !== 'true';
  playButton.setAttribute('aria-pressed', String(playing));
  playButton.setAttribute('aria-label', playing ? playbackText.pause : playbackText.resume);
  playButton.querySelector('use').setAttribute('href', playing ? '#i-pause' : '#i-play');
  document.querySelector('#playback-status').textContent = playing ? playbackText.playing : playbackText.paused;
});

const tabs = [...document.querySelectorAll('[role="tab"]')];
function selectTab(selected) {
  for (const tab of tabs) {
    const active = tab === selected;
    tab.setAttribute('aria-selected', String(active));
    tab.tabIndex = active ? 0 : -1;
    document.getElementById(tab.getAttribute('aria-controls')).hidden = !active;
  }
}
for (const [index, tab] of tabs.entries()) {
  tab.addEventListener('click', () => selectTab(tab));
  tab.addEventListener('keydown', (event) => {
    let next;
    if (event.key === 'ArrowDown') next = (index + 1) % tabs.length;
    else if (event.key === 'ArrowUp') next = (index - 1 + tabs.length) % tabs.length;
    else if (event.key === 'Home') next = 0;
    else if (event.key === 'End') next = tabs.length - 1;
    else return;
    event.preventDefault();
    selectTab(tabs[next]);
    tabs[next].focus();
  });
}

const motionPreference = window.matchMedia('(prefers-reduced-motion: no-preference)');
const cinemaStage = document.querySelector('.cinema-stage');
let parallaxFrame = 0;
function updateParallax() {
  parallaxFrame = 0;
  const stageBottom = cinemaStage.getBoundingClientRect().bottom + window.scrollY;
  const progress = Math.min(1, Math.max(0, window.scrollY / Math.max(1, stageBottom)));
  cinemaStage.style.setProperty('--hero-scroll', progress);
}
function scheduleParallax() {
  if (!parallaxFrame) parallaxFrame = window.requestAnimationFrame(updateParallax);
}
function syncParallax() {
  if (motionPreference.matches) {
    window.addEventListener('scroll', scheduleParallax, { passive: true });
    window.addEventListener('resize', scheduleParallax);
    scheduleParallax();
  } else {
    window.removeEventListener('scroll', scheduleParallax);
    window.removeEventListener('resize', scheduleParallax);
    window.cancelAnimationFrame(parallaxFrame);
    parallaxFrame = 0;
    cinemaStage.style.removeProperty('--hero-scroll');
  }
}
motionPreference.addEventListener('change', syncParallax);
syncParallax();

if ('IntersectionObserver' in window && motionPreference.matches) {
  const revealObserver = new window.IntersectionObserver((entries) => {
    for (const entry of entries) {
      if (!entry.isIntersecting) continue;
      entry.target.classList.add('scroll-reveal');
      revealObserver.unobserve(entry.target);
    }
  }, { threshold: 0.12 });
  for (const element of document.querySelectorAll('.section-heading, .steps article, .feature-explorer, .feature-details > div, .privacy-card, .faq-section > div, .download-section')) {
    revealObserver.observe(element);
  }
}

const playButton = document.querySelector('#demo-play');
playButton.addEventListener('click', () => {
  const playing = playButton.getAttribute('aria-pressed') !== 'true';
  playButton.setAttribute('aria-pressed', String(playing));
  playButton.setAttribute('aria-label', playing ? 'Поставить демонстрацию на паузу' : 'Продолжить демонстрацию');
  playButton.querySelector('use').setAttribute('href', playing ? '#i-pause' : '#i-play');
  document.querySelector('#playback-status').textContent = playing ? 'Воспроизводится на телевизоре' : 'На паузе';
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

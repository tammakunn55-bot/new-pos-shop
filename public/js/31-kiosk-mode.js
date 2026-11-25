(function () {
  'use strict';

  var KEEP_KEY = 'pos_keep_screen_on';
  var FULLSCREEN_KEY = 'pos_auto_fullscreen';
  var wakeLock = null;
  var gestureHandled = false;

  var keepScreenOn = function () {
    return localStorage.getItem(KEEP_KEY) !== '0';
  };

  var setKeepScreenOn = function (enabled) {
    localStorage.setItem(KEEP_KEY, enabled ? '1' : '0');
    if (enabled) acquireWakeLock();
    else releaseWakeLock();
  };

  var acquireWakeLock = async function () {
    if (!keepScreenOn() || document.hidden || !('wakeLock' in navigator)) return;
    try {
      if (wakeLock && !wakeLock.released) return;
      wakeLock = await navigator.wakeLock.request('screen');
      wakeLock.addEventListener('release', function () { wakeLock = null; });
    } catch (_) {}
  };

  var releaseWakeLock = async function () {
    if (!wakeLock) return;
    try { await wakeLock.release(); } catch (_) {}
    wakeLock = null;
  };

  var enterFullscreen = async function () {
    if (!document.fullscreenEnabled || document.fullscreenElement) return;
    try { await document.documentElement.requestFullscreen(); } catch (_) {}
  };

  var setAutoFullscreen = function (enabled) {
    localStorage.setItem(FULLSCREEN_KEY, enabled ? '1' : '0');
    if (enabled) enterFullscreen();
  };

  document.addEventListener('visibilitychange', function () {
    if (!document.hidden) acquireWakeLock();
  });

  function handleFirstGesture() {
    if (gestureHandled) return;
    gestureHandled = true;
    acquireWakeLock();
    if (localStorage.getItem(FULLSCREEN_KEY) === '1') enterFullscreen();
  }

  document.addEventListener('pointerdown', handleFirstGesture, { once: true });
  document.addEventListener('keydown', handleFirstGesture, { once: true });
  acquireWakeLock();

  window.posKiosk = {
    keepScreenOn: keepScreenOn,
    setKeepScreenOn: setKeepScreenOn,
    enterFullscreen: enterFullscreen,
    setAutoFullscreen: setAutoFullscreen,
    exitFullscreen: function () {
      if (document.fullscreenElement) document.exitFullscreen().catch(function () {});
    }
  };

  function addSettingsRows() {
    var modal = document.getElementById('pos-settings-modal');
    if (!modal || modal.querySelector('#pvs-kiosk-row')) return;
    var host = modal.querySelector('.pos-card');
    if (!host) return;
    var box = document.createElement('div');
    box.id = 'pvs-kiosk-row';
    box.innerHTML =
      '<div class="row"><div><b>☀️ ไม่ให้หน้าจอดับขณะเปิดโปรแกรม</b><div style="font-size:12px;color:#64748b">คงหน้าจอไว้ระหว่างใช้งาน POS</div></div><input id="pvs-wake" type="checkbox" style="width:24px;height:24px"></div>' +
      '<div class="row"><div><b>⛶ เปิดแบบเต็มหน้าจอ</b><div style="font-size:12px;color:#64748b">ขอครั้งแรกหลังแตะหน้าจอหรือกดปุ่ม</div></div><button id="pvs-fullscreen" type="button" style="border:0;border-radius:10px;padding:10px 14px;background:#e0e7ff;color:#3730a3;font-weight:800">เปิดเต็มจอ</button></div>';
    var actionRow = host.querySelector('#pvs-reset')?.parentElement;
    host.insertBefore(box, actionRow || null);
    document.getElementById('pvs-wake').checked = keepScreenOn();
    document.getElementById('pvs-wake').onchange = function (event) {
      setKeepScreenOn(event.target.checked);
    };
    document.getElementById('pvs-fullscreen').onclick = function () {
      if (document.fullscreenElement) window.posKiosk.exitFullscreen();
      else enterFullscreen();
    };
  }

  var originalOpenSettings = window.posOpenSettings;
  window.posOpenSettings = function () {
    if (typeof originalOpenSettings === 'function') originalOpenSettings();
    addSettingsRows();
  };

  if (window.posHub) {
    window.posHub.register({
      id: 'kiosk',
      group: 'look',
      icon: '☀️',
      label: 'โหมดหน้าจอ POS',
      hint: 'ไม่ให้หน้าจอดับ • เต็มหน้าจอ',
      run: function () {
        window.posOpenSettings();
        setTimeout(function () {
          var row = document.getElementByById('pvs-kiosk-row');
          if (row) row.scrollIntoView({ block: 'center' });
        }, 30);
      }
    });
  }
})();

/* Cruise Dispatch: notices on the operators' phones (2026-11-16, CLAUDE.md #90).
 * Push ONLY: no fetch handler and no cache, so it never serves an old panel
 * (the panel's boot clears every OTHER service worker; this one is kept).
 * One notification per kind: the same `tag` replaces the previous one. */
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (event) => event.waitUntil(self.clients.claim()));

self.addEventListener("push", (event) => {
  let d = {};
  try {
    d = event.data ? event.data.json() : {};
  } catch (e) {
    d = { title: "Cruise Dispatch", body: event.data ? event.data.text() : "" };
  }
  event.waitUntil(
    self.registration.showNotification(d.title || "Cruise Dispatch", {
      body: d.body || "",
      tag: d.tag || "cruise",
      renotify: true,
      icon: "/panel/icons/icon-192.png",
      badge: "/panel/icons/icon-192.png",
      data: { url: d.url || "/inicio" },
    })
  );
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const path = (event.notification.data && event.notification.data.url) || "/inicio";
  const url = "/panel/#" + (path.charAt(0) === "/" ? path : "/" + path);
  event.waitUntil(
    self.clients.matchAll({ type: "window", includeUncontrolled: true }).then((list) => {
      for (const c of list) {
        if (c.url.indexOf("/panel") !== -1) {
          if ("navigate" in c) {
            return c.navigate(url).then((w) => (w || c).focus()).catch(() => c.focus());
          }
          return c.focus();
        }
      }
      return self.clients.openWindow(url);
    })
  );
});

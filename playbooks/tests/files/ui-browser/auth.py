from __future__ import annotations

from typing import Any


def login(page: Any, base_url: str, username: str, password: str, timeout_ms: int) -> None:
    page.goto(f"{base_url}/users/login", wait_until="domcontentloaded", timeout=timeout_ms)
    page.locator("input[name='login[login]']").fill(username)
    page.locator("input[name='login[password]']").fill(password)

    submit = page.locator(
        "input[type='submit'], button[type='submit'], button:has-text('Log in'), button:has-text('Login')"
    ).first
    submit.click()

    page.wait_for_load_state("domcontentloaded", timeout=timeout_ms)
    page.wait_for_load_state("networkidle", timeout=timeout_ms)


def inject_metric_observers(context: Any) -> None:
    context.add_init_script(
        """
        (() => {
          window.__satperfMetrics = {
            largestContentfulPaint: null,
            cls: 0,
            longTasks: {
              count: 0,
              totalDuration: 0,
              totalBlockingTime: 0,
              maxDuration: 0,
              samples: [],
            },
          };

          try {
            new PerformanceObserver((entryList) => {
              const entries = entryList.getEntries();
              const lastEntry = entries[entries.length - 1];
              if (lastEntry) {
                window.__satperfMetrics.largestContentfulPaint = lastEntry.startTime;
              }
            }).observe({ type: 'largest-contentful-paint', buffered: true });
          } catch (_err) {}

          try {
            new PerformanceObserver((entryList) => {
              for (const entry of entryList.getEntries()) {
                if (!entry.hadRecentInput) {
                  window.__satperfMetrics.cls += entry.value;
                }
              }
            }).observe({ type: 'layout-shift', buffered: true });
          } catch (_err) {}

          try {
            new PerformanceObserver((entryList) => {
              for (const entry of entryList.getEntries()) {
                const duration = entry.duration || 0;
                const blockingTime = Math.max(0, duration - 50);
                const metrics = window.__satperfMetrics.longTasks;
                metrics.count += 1;
                metrics.totalDuration += duration;
                metrics.totalBlockingTime += blockingTime;
                metrics.maxDuration = Math.max(metrics.maxDuration, duration);
                metrics.samples.push({
                  startTime: entry.startTime,
                  duration,
                  blockingTime,
                  name: entry.name || 'longtask',
                });
                metrics.samples.sort((a, b) => b.duration - a.duration);
                metrics.samples = metrics.samples.slice(0, 5);
              }
            }).observe({ type: 'longtask', buffered: true });
          } catch (_err) {}
        })();
        """
    )

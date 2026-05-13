#!/bin/bash
# =============================================================================
# PakWeather — EC2 User Data / Boot Script  (Amazon Linux 2023)
# =============================================================================
set -euo pipefail
exec > /var/log/pakweather-setup.log 2>&1

echo "=== PakWeather boot script started at $(date) ==="

# ── 1. Variables  ──  UPDATE S3_BUCKET before deploying ──────────────────────
S3_BUCKET="pakweather-data-502274764129"   # <-- replace ACCOUNTID with your 12-digit AWS account ID
AWS_REGION="ap-south-1"
APP_DIR="/opt/pakweather"
APP_USER="pakweather"

# ── 2. Install Node.js 20 and AWS CLI ─────────────────────────────────────────
echo "--- Installing Node.js and AWS CLI ---"
dnf install -y nodejs aws-cli
node --version

# ── 3. Create app user and directory ─────────────────────────────────────────
echo "--- Setting up app user and directory ---"
id -u "$APP_USER" &>/dev/null || useradd -r -s /sbin/nologin "$APP_USER"
mkdir -p "$APP_DIR"

# ── 4. Write application files ───────────────────────────────────────────────
echo "--- Writing application files ---"

cat > "$APP_DIR/server.js" << 'SERVEREOF'
'use strict';

const http    = require('http');
const https   = require('https');
const fs      = require('fs');
const path    = require('path');
const { execSync } = require('child_process');

// ── Config ────────────────────────────────────────────────────────────────────
const PORT       = process.env.PORT       || 80;
const S3_BUCKET  = process.env.S3_BUCKET  || 'pakweather-data-502274764129';
const AWS_REGION = process.env.AWS_REGION || 'ap-south-1';
const DATA_KEY   = 'data/weather-latest.json';
const CACHE_TTL  = 2 * 60 * 1000; // 2 minutes

// ── In-memory cache ───────────────────────────────────────────────────────────
let weatherCache   = null;
let cacheTimestamp = 0;

// ── S3 helper (uses AWS CLI on the instance) ──────────────────────────────────
function fetchFromS3() {
  try {
    const raw = execSync(
      `aws s3 cp s3://${S3_BUCKET}/${DATA_KEY} - --region ${AWS_REGION}`,
      { timeout: 10000 }
    ).toString();
    return JSON.parse(raw);
  } catch (e) {
    console.error('[server] S3 fetch failed:', e.message);
    return null;
  }
}

function getWeather() {
  const now = Date.now();
  if (weatherCache && (now - cacheTimestamp) < CACHE_TTL) return weatherCache;
  const fresh = fetchFromS3();
  if (fresh) {
    weatherCache   = fresh;
    cacheTimestamp = now;
  }
  return weatherCache;
}

// ── HTML renderer ─────────────────────────────────────────────────────────────
function weatherIcon(code) {
  // WMO weather code → emoji
  if (code === 0)               return '☀️';
  if (code <= 2)                return '⛅';
  if (code <= 3)                return '☁️';
  if (code <= 49)               return '🌫️';
  if (code <= 59)               return '🌦️';
  if (code <= 69)               return '🌧️';
  if (code <= 79)               return '❄️';
  if (code <= 82)               return '🌧️';
  if (code <= 84)               return '🌨️';
  if (code <= 94)               return '⛈️';
  return '🌩️';
}

function conditionLabel(code) {
  if (code === 0)  return 'Clear Sky';
  if (code <= 2)   return 'Partly Cloudy';
  if (code <= 3)   return 'Overcast';
  if (code <= 49)  return 'Foggy';
  if (code <= 59)  return 'Drizzle';
  if (code <= 69)  return 'Rain';
  if (code <= 79)  return 'Snow';
  if (code <= 82)  return 'Showers';
  if (code <= 84)  return 'Snow Showers';
  if (code <= 94)  return 'Thunderstorm';
  return 'Severe Storm';
}

function renderForecast(days) {
  return days.map(d => `
    <div class="forecast-day">
      <span class="f-date">${d.date}</span>
      <span class="f-icon">${weatherIcon(d.weatherCode)}</span>
      <span class="f-range">${d.tempMin}° / ${d.tempMax}°</span>
      <span class="f-label">${conditionLabel(d.weatherCode)}</span>
    </div>`).join('');
}

function renderCard(city) {
  return `
  <div class="card">
    <div class="card-header">
      <div class="city-name">${city.name}</div>
      <div class="city-province">${city.province}</div>
    </div>
    <div class="card-body">
      <div class="main-weather">
        <span class="weather-icon">${weatherIcon(city.current.weatherCode)}</span>
        <span class="temp">${city.current.temp}°C</span>
      </div>
      <div class="condition">${conditionLabel(city.current.weatherCode)}</div>
      <div class="details">
        <div class="detail-item">💧 <strong>${city.current.humidity}%</strong><br>Humidity</div>
        <div class="detail-item">💨 <strong>${city.current.windspeed} km/h</strong><br>Wind</div>
        <div class="detail-item">🌡️ <strong>${city.current.feelsLike}°C</strong><br>Feels Like</div>
        <div class="detail-item">☁️ <strong>${city.current.cloudcover}%</strong><br>Cloud Cover</div>
      </div>
    </div>
    <div class="forecast">
      <div class="forecast-title">3-Day Forecast</div>
      <div class="forecast-days">${renderForecast(city.forecast)}</div>
    </div>
    <div class="card-footer">Updated: ${city.updatedAt}</div>
  </div>`;
}

function renderPage(data) {
  const cards  = data ? data.cities.map(renderCard).join('') : '';
  const updated = data ? data.fetchedAt : 'Not yet loaded';
  const noData  = !data ? `
    <div class="no-data">
      <span style="font-size:3rem">⏳</span>
      <p>Weather data not loaded yet. The background fetcher runs every 30 minutes.</p>
      <p>Please wait a moment and refresh.</p>
    </div>` : '';

  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>PakWeather — Live Weather for Pakistani Cities</title>
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
      background: linear-gradient(135deg, #0f2027, #203a43, #2c5364);
      min-height: 100vh;
      color: #fff;
    }
    header {
      background: rgba(0,0,0,0.4);
      padding: 24px 32px;
      display: flex;
      align-items: center;
      justify-content: space-between;
      backdrop-filter: blur(8px);
      border-bottom: 1px solid rgba(255,255,255,0.1);
    }
    .logo { font-size: 1.8rem; font-weight: 700; letter-spacing: 1px; }
    .logo span { color: #56ccf2; }
    .last-update { font-size: 0.8rem; color: rgba(255,255,255,0.5); }
    main { max-width: 1400px; margin: 0 auto; padding: 40px 24px; }
    h2.section-title {
      font-size: 1.3rem;
      color: rgba(255,255,255,0.7);
      margin-bottom: 28px;
      font-weight: 400;
    }
    .grid {
      display: grid;
      grid-template-columns: repeat(auto-fill, minmax(300px, 1fr));
      gap: 24px;
    }
    .card {
      background: rgba(255,255,255,0.08);
      border-radius: 16px;
      overflow: hidden;
      border: 1px solid rgba(255,255,255,0.12);
      backdrop-filter: blur(12px);
      transition: transform 0.2s, box-shadow 0.2s;
    }
    .card:hover {
      transform: translateY(-4px);
      box-shadow: 0 12px 40px rgba(0,0,0,0.4);
    }
    .card-header {
      background: linear-gradient(135deg, rgba(86,204,242,0.25), rgba(47,128,237,0.25));
      padding: 18px 20px 14px;
      border-bottom: 1px solid rgba(255,255,255,0.1);
    }
    .city-name    { font-size: 1.4rem; font-weight: 700; }
    .city-province{ font-size: 0.8rem; color: rgba(255,255,255,0.6); margin-top: 2px; }
    .card-body    { padding: 20px; }
    .main-weather { display: flex; align-items: center; gap: 12px; margin-bottom: 6px; }
    .weather-icon { font-size: 3rem; }
    .temp         { font-size: 3rem; font-weight: 300; }
    .condition    { font-size: 0.95rem; color: rgba(255,255,255,0.65); margin-bottom: 18px; }
    .details {
      display: grid;
      grid-template-columns: 1fr 1fr;
      gap: 10px;
    }
    .detail-item {
      background: rgba(255,255,255,0.07);
      border-radius: 10px;
      padding: 10px 12px;
      font-size: 0.82rem;
      color: rgba(255,255,255,0.75);
      line-height: 1.5;
    }
    .detail-item strong { color: #fff; font-size: 1rem; display: block; }
    .forecast          { padding: 16px 20px; border-top: 1px solid rgba(255,255,255,0.08); }
    .forecast-title    { font-size: 0.75rem; text-transform: uppercase; letter-spacing: 1px; color: rgba(255,255,255,0.45); margin-bottom: 10px; }
    .forecast-days     { display: flex; gap: 8px; }
    .forecast-day {
      flex: 1;
      background: rgba(255,255,255,0.06);
      border-radius: 10px;
      padding: 10px 6px;
      text-align: center;
      font-size: 0.75rem;
    }
    .f-date  { display: block; color: rgba(255,255,255,0.5); margin-bottom: 4px; }
    .f-icon  { display: block; font-size: 1.3rem; margin: 4px 0; }
    .f-range { display: block; font-weight: 600; margin-bottom: 2px; }
    .f-label { display: block; color: rgba(255,255,255,0.5); font-size: 0.68rem; }
    .card-footer {
      padding: 8px 20px;
      font-size: 0.72rem;
      color: rgba(255,255,255,0.3);
      background: rgba(0,0,0,0.15);
      border-top: 1px solid rgba(255,255,255,0.06);
    }
    .no-data {
      text-align: center;
      padding: 80px 20px;
      color: rgba(255,255,255,0.5);
    }
    .no-data p { margin-top: 16px; font-size: 1.1rem; }
    footer {
      text-align: center;
      padding: 32px;
      color: rgba(255,255,255,0.25);
      font-size: 0.8rem;
    }
  </style>
</head>
<body>
  <header>
    <div class="logo">Pak<span>Weather</span></div>
    <div class="last-update">Data fetched: ${updated}</div>
  </header>
  <main>
    <h2 class="section-title">🇵🇰 Live Weather — Major Pakistani Cities</h2>
    <div class="grid">${cards}</div>
    ${noData}
  </main>
  <footer>PakWeather &mdash; CE 308/408 Cloud Computing Assignment &mdash; GIKI &mdash; Powered by AWS &amp; Open-Meteo API</footer>
</body>
</html>`;
}

// ── HTTP Server ───────────────────────────────────────────────────────────────
const server = http.createServer((req, res) => {
  if (req.method === 'GET' && req.url === '/health') {
    res.writeHead(200, { 'Content-Type': 'text/plain' });
    return res.end('OK');
  }
  if (req.method === 'GET' && (req.url === '/' || req.url === '/index.html')) {
    const data = getWeather();
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    return res.end(renderPage(data));
  }
  res.writeHead(404, { 'Content-Type': 'text/plain' });
  res.end('Not Found');
});

server.listen(PORT, () => {
  console.log(`[server] PakWeather running on port ${PORT}`);
});
SERVEREOF

cat > "$APP_DIR/pakweather-fetch.js" << 'FETCHEOF'
#!/usr/bin/env node
'use strict';

/**
 * pakweather-fetch.js
 *
 * Runs on every EC2 instance via a systemd timer (every 30 minutes).
 * Only ONE instance wins the S3 lock and calls the Open-Meteo API.
 * All instances share the result from S3.
 */

const https   = require('https');
const { execSync, spawnSync } = require('child_process');

const S3_BUCKET  = process.env.S3_BUCKET  || 'pakweather-data-502274764129';
const AWS_REGION = process.env.AWS_REGION || 'ap-south-1';
const LOCK_KEY   = 'locks/ingestion.lock';
const DATA_KEY   = 'data/weather-latest.json';

// Pakistani cities with their coordinates
const CITIES = [
  { name: 'Islamabad',  province: 'Federal Capital',  lat: 33.6844, lon: 73.0479 },
  { name: 'Lahore',     province: 'Punjab',            lat: 31.5204, lon: 74.3587 },
  { name: 'Karachi',    province: 'Sindh',             lat: 24.8607, lon: 67.0011 },
  { name: 'Peshawar',   province: 'Khyber Pakhtunkhwa',lat: 34.0150, lon: 71.5249 },
  { name: 'Quetta',     province: 'Balochistan',       lat: 30.1798, lon: 66.9750 },
  { name: 'Multan',     province: 'Punjab',            lat: 30.1575, lon: 71.5249 },
  { name: 'Faisalabad', province: 'Punjab',            lat: 31.4504, lon: 73.1350 },
  { name: 'Rawalpindi', province: 'Punjab',            lat: 33.5651, lon: 73.0169 },
];

// ── S3 helpers ────────────────────────────────────────────────────────────────
function s3Put(key, content) {
  const tmpFile = `/tmp/pakweather-${Date.now()}.json`;
  require('fs').writeFileSync(tmpFile, content);
  execSync(`aws s3 cp ${tmpFile} s3://${S3_BUCKET}/${key} --region ${AWS_REGION}`, { timeout: 15000 });
  require('fs').unlinkSync(tmpFile);
}

function s3Exists(key) {
  const r = spawnSync('aws', ['s3api', 'head-object', '--bucket', S3_BUCKET, '--key', key, '--region', AWS_REGION]);
  return r.status === 0;
}

function s3Delete(key) {
  try {
    execSync(`aws s3 rm s3://${S3_BUCKET}/${key} --region ${AWS_REGION}`, { timeout: 10000 });
  } catch (_) {}
}

// ── Distributed lock ──────────────────────────────────────────────────────────
function acquireLock() {
  if (s3Exists(LOCK_KEY)) {
    console.log('[fetcher] Lock exists — another instance is fetching. Exiting.');
    return false;
  }
  s3Put(LOCK_KEY, JSON.stringify({ lockedAt: new Date().toISOString(), pid: process.pid }));
  console.log('[fetcher] Lock acquired.');
  return true;
}

function releaseLock() {
  s3Delete(LOCK_KEY);
  console.log('[fetcher] Lock released.');
}

// ── Open-Meteo API ────────────────────────────────────────────────────────────
function httpsGet(url) {
  return new Promise((resolve, reject) => {
    https.get(url, res => {
      let body = '';
      res.on('data', chunk => body += chunk);
      res.on('end', () => {
        try { resolve(JSON.parse(body)); }
        catch (e) { reject(new Error('JSON parse error: ' + e.message)); }
      });
    }).on('error', reject);
  });
}

async function fetchCityWeather(city) {
  // Open-Meteo: free, no API key, returns current + daily forecast
  const url = `https://api.open-meteo.com/v1/forecast`
    + `?latitude=${city.lat}&longitude=${city.lon}`
    + `&current=temperature_2m,relative_humidity_2m,apparent_temperature,weather_code,wind_speed_10m,cloud_cover`
    + `&daily=weather_code,temperature_2m_max,temperature_2m_min`
    + `&forecast_days=3`
    + `&timezone=Asia%2FKarachi`;

  const data = await httpsGet(url);
  const c    = data.current;
  const d    = data.daily;

  const forecast = d.time.map((date, i) => ({
    date:        date,
    weatherCode: d.weather_code[i],
    tempMax:     Math.round(d.temperature_2m_max[i]),
    tempMin:     Math.round(d.temperature_2m_min[i]),
  }));

  return {
    name:     city.name,
    province: city.province,
    current: {
      temp:        Math.round(c.temperature_2m),
      feelsLike:   Math.round(c.apparent_temperature),
      humidity:    c.relative_humidity_2m,
      windspeed:   Math.round(c.wind_speed_10m),
      cloudcover:  c.cloud_cover,
      weatherCode: c.weather_code,
    },
    forecast,
    updatedAt: new Date().toLocaleString('en-PK', { timeZone: 'Asia/Karachi' }),
  };
}

// ── Main ──────────────────────────────────────────────────────────────────────
(async () => {
  console.log('[fetcher] PakWeather fetch starting at', new Date().toISOString());

  if (!acquireLock()) process.exit(0);

  try {
    console.log('[fetcher] Fetching weather for', CITIES.length, 'cities...');
    const cities = await Promise.all(CITIES.map(fetchCityWeather));
    console.log('[fetcher] All cities fetched successfully.');

    const payload = JSON.stringify({
      fetchedAt: new Date().toLocaleString('en-PK', { timeZone: 'Asia/Karachi' }),
      cities,
    }, null, 2);

    s3Put(DATA_KEY, payload);
    console.log('[fetcher] Weather data written to S3:', DATA_KEY);
  } catch (err) {
    console.error('[fetcher] Error during fetch:', err.message);
  } finally {
    releaseLock();
  }

  process.exit(0);
})();
FETCHEOF

# ── 5. Write package.json ─────────────────────────────────────────────────────
cat > "$APP_DIR/package.json" << 'PKGEOF'
{
  "name": "pakweather",
  "version": "1.0.0",
  "description": "Live weather dashboard for Pakistani cities",
  "main": "server.js",
  "scripts": { "start": "node server.js" },
  "engines": { "node": ">=18" }
}
PKGEOF

chown -R "$APP_USER:$APP_USER" "$APP_DIR"

# ── 6. systemd unit — web server ──────────────────────────────────────────────
echo "--- Creating pakweather.service ---"
cat > /etc/systemd/system/pakweather.service << EOF
[Unit]
Description=PakWeather Web Server
After=network.target

[Service]
Type=simple
User=$APP_USER
WorkingDirectory=$APP_DIR
Environment=PORT=80
Environment=S3_BUCKET=$S3_BUCKET
Environment=AWS_REGION=$AWS_REGION
ExecStart=/usr/bin/node $APP_DIR/server.js
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# ── 7. systemd unit + timer — background fetcher ──────────────────────────────
echo "--- Creating pakweather-fetch service and timer ---"
cat > /etc/systemd/system/pakweather-fetch.service << EOF
[Unit]
Description=PakWeather Background Weather Fetcher
After=network.target

[Service]
Type=oneshot
User=$APP_USER
WorkingDirectory=$APP_DIR
Environment=S3_BUCKET=$S3_BUCKET
Environment=AWS_REGION=$AWS_REGION
ExecStart=/usr/bin/node $APP_DIR/pakweather-fetch.js
EOF

cat > /etc/systemd/system/pakweather-fetch.timer << EOF
[Unit]
Description=Run PakWeather fetcher every 30 minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=30min
Unit=pakweather-fetch.service

[Install]
WantedBy=timers.target
EOF

# ── 8. Enable and start everything ───────────────────────────────────────────
echo "--- Enabling and starting services ---"
systemctl daemon-reload
systemctl enable pakweather.service
systemctl start  pakweather.service
systemctl enable pakweather-fetch.timer
systemctl start  pakweather-fetch.timer

# Run first fetch immediately (don't wait 30 minutes)
systemctl start pakweather-fetch.service || true

echo "=== PakWeather boot script completed at $(date) ==="

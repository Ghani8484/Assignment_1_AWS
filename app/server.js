'use strict';

const http    = require('http');
const https   = require('https');
const fs      = require('fs');
const path    = require('path');
const { execSync } = require('child_process');

// ── Config ────────────────────────────────────────────────────────────────────
const PORT       = process.env.PORT       || 80;
const S3_BUCKET  = process.env.S3_BUCKET  || 'pakweather-data-ACCOUNTID';
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

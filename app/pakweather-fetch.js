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

const S3_BUCKET  = process.env.S3_BUCKET  || 'pakweather-data-ACCOUNTID';
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

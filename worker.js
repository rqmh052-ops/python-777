/**
 * Bynux private script API for Cloudflare Workers + R2.
 * Required bindings:
 *   FILES             -> private R2 bucket binding
 *   GOOGLE_CLIENT_ID  -> Web OAuth client ID (plain text variable)
 * No APP_TOKEN is used; Google ID tokens provide the user identity.
 */
const MAX_FILE_BYTES = 1024 * 1024;
const MAX_FILES_PER_USER = 200;
const PROFILE_FILE = '.bynux-profile.json';
const GOOGLE_CERTS_URL = 'https://www.googleapis.com/oauth2/v3/certs';

let cachedGoogleKeys = null;
let googleKeysExpiresAt = 0;

function json(data, status = 200, extraHeaders = {}) {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      'content-type': 'application/json; charset=utf-8',
      'cache-control': 'no-store',
      'x-content-type-options': 'nosniff',
      ...extraHeaders,
    },
  });
}

function error(message, status, extraHeaders = {}) {
  return json({ ok: false, error: message }, status, extraHeaders);
}

function decodeBase64Url(value) {
  const normalized = value.replace(/-/g, '+').replace(/_/g, '/');
  const padded = normalized + '='.repeat((4 - (normalized.length % 4)) % 4);
  const raw = atob(padded);
  const bytes = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; i++) bytes[i] = raw.charCodeAt(i);
  return bytes;
}

async function googleKeys() {
  if (cachedGoogleKeys && Date.now() < googleKeysExpiresAt) return cachedGoogleKeys;
  const response = await fetch(GOOGLE_CERTS_URL, {
    cf: { cacheTtl: 1800, cacheEverything: true },
  });
  if (!response.ok) throw new Error('Google signing keys are unavailable');
  const data = await response.json();
  const cacheControl = response.headers.get('cache-control') || '';
  const maxAge = Number(cacheControl.match(/max-age=(\d+)/i)?.[1] || 1800);
  cachedGoogleKeys = Array.isArray(data.keys) ? data.keys : [];
  googleKeysExpiresAt = Date.now() + Math.max(300, Math.min(maxAge, 21600)) * 1000;
  if (!cachedGoogleKeys.length) throw new Error('Google signing keys response was empty');
  return cachedGoogleKeys;
}

async function verifyGoogleIdToken(request, env) {
  const header = request.headers.get('authorization') || '';
  const match = header.match(/^Bearer\s+(.+)$/i);
  if (!match) return { ok: false, status: 401, message: 'Missing bearer token' };

  const token = match[1].trim();
  const parts = token.split('.');
  if (parts.length !== 3) return { ok: false, status: 401, message: 'Invalid token format' };

  try {
    const headerData = JSON.parse(new TextDecoder().decode(decodeBase64Url(parts[0])));
    const claims = JSON.parse(new TextDecoder().decode(decodeBase64Url(parts[1])));
    if (headerData.alg !== 'RS256' || typeof headerData.kid !== 'string') {
      return { ok: false, status: 401, message: 'Unsupported token signature' };
    }

    const now = Math.floor(Date.now() / 1000);
    const audienceMatches = claims.aud === env.GOOGLE_CLIENT_ID ||
      (Array.isArray(claims.aud) && claims.aud.includes(env.GOOGLE_CLIENT_ID) &&
        claims.azp === env.GOOGLE_CLIENT_ID);
    const issuerMatches = claims.iss === 'https://accounts.google.com' ||
      claims.iss === 'accounts.google.com';

    if (!audienceMatches || !issuerMatches || !claims.sub ||
        !Number.isFinite(claims.exp) || claims.exp <= now ||
        !Number.isFinite(claims.iat) || claims.iat > now + 300 ||
        (claims.email_verified !== true && claims.email_verified !== 'true')) {
      return { ok: false, status: 401, message: 'Invalid or expired Google token' };
    }
    if (!/^[A-Za-z0-9_-]{1,255}$/.test(String(claims.sub))) {
      return { ok: false, status: 401, message: 'Invalid user identity' };
    }

    const keys = await googleKeys();
    const signingKey = keys.find((key) => key.kid === headerData.kid && key.kty === 'RSA');
    if (!signingKey) return { ok: false, status: 401, message: 'Unknown signing key' };
    const publicKey = await crypto.subtle.importKey(
      'jwk', signingKey,
      { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
      false, ['verify'],
    );
    const signingInput = new TextEncoder().encode(`${parts[0]}.${parts[1]}`);
    const signature = decodeBase64Url(parts[2]);
    const validSignature = await crypto.subtle.verify(
      { name: 'RSASSA-PKCS1-v1_5' }, publicKey, signature, signingInput,
    );
    if (!validSignature) return { ok: false, status: 401, message: 'Invalid token signature' };

    return {
      ok: true,
      user: {
        sub: String(claims.sub),
        email: typeof claims.email === 'string' ? claims.email : '',
      },
    };
  } catch (_) {
    return { ok: false, status: 401, message: 'Unable to verify Google token' };
  }
}

function safeScriptName(raw) {
  let name;
  try {
    name = decodeURIComponent(raw);
  } catch (_) {
    return null;
  }
  if (!name || name.length > 180 || name.includes('/') || name.includes('\\') ||
      name.includes('..') || /[\u0000-\u001f\u007f]/.test(name) ||
      !name.toLowerCase().endsWith('.py')) return null;
  return name;
}

function userPrefix(user) {
  return `users/${user.sub}/`;
}

function profileKey(user) {
  return `${userPrefix(user)}${PROFILE_FILE}`;
}

async function readProfile(env, user) {
  const key = profileKey(user);
  const object = await env.FILES.get(key);
  if (!object) {
    const profile = {
      email: user.email,
      createdAt: new Date().toISOString(),
      lastUpload: null,
    };
    await env.FILES.put(key, JSON.stringify(profile), {
      httpMetadata: { contentType: 'application/json; charset=utf-8', cacheControl: 'private, no-store' },
    });
    return profile;
  }

  let profile;
  let needsWrite = false;
  try {
    profile = await object.json();
  } catch (_) {
    profile = null;
  }
  if (!profile || typeof profile !== 'object' || typeof profile.createdAt !== 'string') {
    profile = { email: user.email, createdAt: new Date().toISOString(), lastUpload: null };
    needsWrite = true;
  }
  if (user.email && profile.email !== user.email) {
    profile.email = user.email;
    needsWrite = true;
  }
  if (!Object.prototype.hasOwnProperty.call(profile, 'lastUpload')) {
    profile.lastUpload = null;
    needsWrite = true;
  }
  if (needsWrite) {
    await env.FILES.put(key, JSON.stringify(profile), {
      httpMetadata: { contentType: 'application/json; charset=utf-8', cacheControl: 'private, no-store' },
    });
  }
  return profile;
}

async function listUserFiles(env, user) {
  const prefix = userPrefix(user);
  const files = [];
  let cursor;
  do {
    const page = await env.FILES.list({ prefix, limit: 1000, cursor });
    for (const object of page.objects) {
      const name = object.key.slice(prefix.length);
      if (name === PROFILE_FILE || !safeScriptName(encodeURIComponent(name))) continue;
      files.push({
        name,
        size: object.size,
        uploadedAt: object.customMetadata?.uploadedAt || object.uploaded.toISOString(),
      });
    }
    cursor = page.truncated ? page.cursor : undefined;
  } while (cursor);
  files.sort((a, b) => Date.parse(b.uploadedAt) - Date.parse(a.uploadedAt));
  return files;
}

async function readLimitedBody(request, maxBytes) {
  const length = Number(request.headers.get('content-length') || 0);
  if (length > maxBytes) return { error: 'File is larger than 1 MiB', status: 413 };
  if (!request.body) return { bytes: new Uint8Array() };
  const reader = request.body.getReader();
  const chunks = [];
  let total = 0;
  while (true) {
    const { value, done } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > maxBytes) {
      await reader.cancel();
      return { error: 'File is larger than 1 MiB', status: 413 };
    }
    chunks.push(value);
  }
  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return { bytes };
}

async function handleApi(request, env, user, url) {
  if (!env.FILES) return error('R2 binding FILES is not configured', 503);
  if (!env.GOOGLE_CLIENT_ID) return error('Google client ID is not configured', 503);

  if (url.pathname === '/v1/profile' && request.method === 'GET') {
    const profile = await readProfile(env, user);
    return json({ ok: true, ...profile });
  }

  if (url.pathname === '/v1/files' && request.method === 'GET') {
    const files = await listUserFiles(env, user);
    return json({ ok: true, files });
  }

  const match = url.pathname.match(/^\/v1\/files\/([^/]+)$/);
  if (match && (request.method === 'GET' || request.method === 'PUT')) {
    let rawSegment = match[1];
    const name = safeScriptName(rawSegment);
    if (!name) return error('Invalid Python script name', 400);
    const key = `${userPrefix(user)}${name}`;

    if (request.method === 'GET') {
      const object = await env.FILES.get(key);
      if (!object) return error('File not found', 404);
      const headers = new Headers();
      object.writeHttpMetadata(headers);
      headers.set('cache-control', 'private, no-store');
      headers.set('x-content-type-options', 'nosniff');
      headers.set('content-type', 'text/x-python; charset=utf-8');
      headers.set('content-disposition', `attachment; filename*=UTF-8''${encodeURIComponent(name)}`);
      headers.set('content-length', String(object.size));
      return new Response(object.body, { status: 200, headers });
    }

    const body = await readLimitedBody(request, MAX_FILE_BYTES);
    if (body.error) return error(body.error, body.status);
    const existing = await env.FILES.head(key);
    if (!existing) {
      const files = await listUserFiles(env, user);
      if (files.length >= MAX_FILES_PER_USER) {
        return error('Maximum of 200 files per account reached', 429);
      }
    }
    const uploadedAt = new Date().toISOString();
    await env.FILES.put(key, body.bytes, {
      httpMetadata: {
        contentType: 'text/x-python; charset=utf-8',
        cacheControl: 'private, no-store',
      },
      customMetadata: { uploadedAt },
    });
    const profile = await readProfile(env, user);
    profile.lastUpload = { name, size: body.bytes.byteLength, uploadedAt };
    profile.email = user.email || profile.email;
    await env.FILES.put(profileKey(user), JSON.stringify(profile), {
      httpMetadata: { contentType: 'application/json; charset=utf-8', cacheControl: 'private, no-store' },
    });
    return json({ ok: true, name, size: body.bytes.byteLength, uploadedAt });
  }

  if (url.pathname.startsWith('/v1/files') || url.pathname === '/v1/profile') {
    return error('Method not allowed', 405, { allow: 'GET, PUT' });
  }
  return error('Not found', 404);
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (request.method === 'OPTIONS') {
      return new Response(null, {
        status: 204,
        headers: {
          'access-control-allow-origin': '*',
          'access-control-allow-methods': 'GET, PUT, OPTIONS',
          'access-control-allow-headers': 'Authorization, Content-Type',
          'access-control-max-age': '86400',
        },
      });
    }

    if (url.pathname === '/v1/health' && request.method === 'GET') {
      return json({
        ok: true,
        storage_bound: Boolean(env.FILES),
        auth_configured: Boolean(env.GOOGLE_CLIENT_ID),
      });
    }

    const verified = await verifyGoogleIdToken(request, env);
    if (!verified.ok) return error(verified.message, verified.status);

    try {
      const response = await handleApi(request, env, verified.user, url);
      response.headers.set('access-control-allow-origin', '*');
      response.headers.set('access-control-allow-methods', 'GET, PUT, OPTIONS');
      response.headers.set('access-control-allow-headers', 'Authorization, Content-Type');
      return response;
    } catch (_) {
      return error('Cloud storage operation failed', 500);
    }
  },
};

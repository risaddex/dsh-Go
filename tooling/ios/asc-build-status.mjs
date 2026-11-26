#!/usr/bin/env node
// App Store Connect, read through its REST API, so a release consult does not hand-roll a JWT.
// The key never leaves this process: a fresh ES256 token is minted for each command and the
// private key is only read from disk. Node only, no dependencies.
//
//   ASC_KEY_ID     App Store Connect key id (default C93V33X8QS)
//   ASC_ISSUER     issuer id, required; no default is kept in the repository
//   ASC_KEY_PATH   the .p8 file (default ~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8)
//
//   node tooling/ios/asc-build-status.mjs builds <appId>
//   node tooling/ios/asc-build-status.mjs compliance <appId> <buildNumber>
//   node tooling/ios/asc-build-status.mjs groups <appId>

import { createPrivateKey, sign } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join } from 'node:path';

const API = 'https://api.appstoreconnect.apple.com';

const usage = `usage:
  node tooling/ios/asc-build-status.mjs builds <appId>
  node tooling/ios/asc-build-status.mjs compliance <appId> <buildNumber>
  node tooling/ios/asc-build-status.mjs groups <appId>

environment:
  ASC_ISSUER     required, the App Store Connect issuer id
  ASC_KEY_ID     the key id (default C93V33X8QS)
  ASC_KEY_PATH   the private key (default ~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8)`;

function tokenHeader() {
  const kid = process.env.ASC_KEY_ID || 'C93V33X8QS';
  const issuer = process.env.ASC_ISSUER;
  if (!issuer) {
    throw new Error(
      'ASC_ISSUER is not set: export the App Store Connect issuer id (Users and Access, Keys, Issuer ID) before running this.',
    );
  }
  const keyPath = process.env.ASC_KEY_PATH || join(homedir(), '.appstoreconnect', 'private_keys', `AuthKey_${kid}.p8`);
  const now = Math.floor(Date.now() / 1000);
  return { kid, issuer, keyPath, now };
}

// Apple accepts a token that lives at most twenty minutes; fifteen keeps a slow command inside it.
async function mintToken() {
  const { kid, issuer, keyPath, now } = tokenHeader();
  let key;
  try {
    key = createPrivateKey(await readFile(keyPath, 'utf8'));
  } catch (error) {
    throw new Error(`cannot read the App Store Connect key ${keyPath}: ${error.message}`);
  }
  const header = { alg: 'ES256', kid, typ: 'JWT' };
  const payload = { iss: issuer, iat: now, exp: now + 15 * 60, aud: 'appstoreconnect-v1' };
  const input = `${Buffer.from(JSON.stringify(header)).toString('base64url')}.${Buffer.from(
    JSON.stringify(payload),
  ).toString('base64url')}`;
  // Apple wants the JWS ECDSA signature (r || s), not the DER encoding crypto.sign gives by default.
  const signature = sign('sha256', Buffer.from(input), { key, dsaEncoding: 'ieee-p1363' });
  return `${input}.${signature.toString('base64url')}`;
}

async function request(token, path, init = {}) {
  let response;
  try {
    response = await fetch(`${API}${path}`, {
      ...init,
      headers: {
        Authorization: `Bearer ${token}`,
        Accept: 'application/json',
        ...(init.body ? { 'Content-Type': 'application/json' } : {}),
      },
    });
  } catch (error) {
    throw new Error(`the request to ${path} did not reach App Store Connect: ${error.message}`);
  }
  const text = await response.text();
  let body;
  try {
    body = text ? JSON.parse(text) : {};
  } catch {
    body = {};
  }
  if (!response.ok) {
    const first = body.errors?.[0];
    const reason = first
      ? [first.status, first.code, first.title, first.detail].filter(Boolean).join(' ')
      : text.slice(0, 300) || 'no body';
    throw new Error(`App Store Connect answered ${response.status} ${response.statusText} for ${path}: ${reason}`);
  }
  return body;
}

function rank(buildNumber) {
  const value = Number(buildNumber);
  return Number.isFinite(value) ? value : Number.NEGATIVE_INFINITY;
}

// filter[app] plus include=preReleaseVersion is where the marketing version comes from; the build
// number is unique per app and grows with every upload, so sorting on it puts the newest first.
async function listBuilds(token, appId) {
  const body = await request(
    token,
    `/v1/builds?filter[app]=${encodeURIComponent(appId)}&include=preReleaseVersion&limit=200&sort=-uploadedDate`,
  );
  const versions = new Map();
  for (const item of body.included ?? []) {
    if (item.type === 'preReleaseVersions') versions.set(item.id, item.attributes?.version);
  }
  return (body.data ?? [])
    .map((build) => {
      const reference = build.relationships?.preReleaseVersion?.data;
      return {
        id: build.id,
        number: String(build.attributes?.version ?? '?'),
        marketing: (reference && versions.get(reference.id)) || '?',
        state: build.attributes?.processingState ?? '?',
        encryption: build.attributes?.usesNonExemptEncryption ?? null,
        uploaded: build.attributes?.uploadedDate ?? '?',
      };
    })
    .sort((a, b) => rank(b.number) - rank(a.number));
}

async function builds(token, [appId]) {
  if (!appId) throw new Error(`builds needs an app id\n${usage}`);
  const list = await listBuilds(token, appId);
  if (list.length === 0) {
    console.log(`app ${appId} has no builds yet.`);
    return;
  }
  for (const build of list) {
    const encryption = build.encryption === null ? 'null' : String(build.encryption);
    console.log(`build ${build.number} | ${build.marketing} | ${build.state} | usesNonExemptEncryption=${encryption} | uploaded ${build.uploaded}`);
  }
}

async function compliance(token, [appId, buildNumber]) {
  if (!appId || !buildNumber) throw new Error(`compliance needs an app id and a build number\n${usage}`);
  const build = (await listBuilds(token, appId)).find((item) => item.number === String(buildNumber));
  if (!build) throw new Error(`app ${appId} has no build ${buildNumber}`);
  if (build.encryption !== null) {
    console.log(`build ${build.number} already answers usesNonExemptEncryption=${build.encryption}; nothing to change.`);
    return;
  }
  const body = await request(token, `/v1/builds/${build.id}`, {
    method: 'PATCH',
    body: JSON.stringify({ data: { type: 'builds', id: build.id, attributes: { usesNonExemptEncryption: false } } }),
  });
  const recorded = body.data?.attributes?.usesNonExemptEncryption;
  console.log(`build ${build.number} had no export-compliance answer; recorded usesNonExemptEncryption=${recorded}.`);
}

async function groups(token, [appId]) {
  if (!appId) throw new Error(`groups needs an app id\n${usage}`);
  const body = await request(token, `/v1/betaGroups?filter[app]=${encodeURIComponent(appId)}&limit=200`);
  const list = body.data ?? [];
  if (list.length === 0) {
    console.log(`app ${appId} has no beta groups.`);
    return;
  }
  let internal = 0;
  for (const group of list) {
    const isInternal = group.attributes?.isInternalGroup === true;
    if (isInternal) internal += 1;
    console.log(`${group.attributes?.name ?? group.id} | isInternalGroup=${isInternal}`);
  }
  if (internal > 0) {
    console.log('An internal group receives builds automatically, so a build is never assigned to one by hand.');
  } else {
    console.log('No internal group here, so every build needs a group assigned before a tester can install it.');
  }
}

const commands = { builds, compliance, groups };

async function main(argv) {
  const [command, ...args] = argv;
  if (!command || command === 'help' || command === '--help' || command === '-h') {
    console.log(usage);
    return 0;
  }
  const handler = commands[command];
  if (!handler) throw new Error(`unknown subcommand "${command}"\n${usage}`);
  await handler(await mintToken(), args);
  return 0;
}

try {
  process.exitCode = await main(process.argv.slice(2));
} catch (error) {
  console.error(`error: ${error.message}`);
  process.exitCode = 1;
}

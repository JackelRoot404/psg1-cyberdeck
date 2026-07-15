#!/usr/bin/env node
// wallet.mjs — minimal Solana wallet via @solana/kit (the JS SDK path).
// Anza ships no aarch64-linux solana-cli, so this is the supported route on the PSG1.
//   node wallet.mjs new               create keypair -> $SOLANA_KEY (default ./id.json)
//   node wallet.mjs show              this wallet's address + balance
//   node wallet.mjs address           print this wallet's address only
//   node wallet.mjs balance <pubkey>  balance for any address
// Env: SOLANA_RPC (default mainnet-beta), SOLANA_KEY (default ./id.json)
import fs from 'node:fs';
import { createSolanaRpc, address, createKeyPairSignerFromBytes } from '@solana/kit';

// hush Node's harmless "Ed25519 Web Crypto ... experimental" notice
const _emit = process.emitWarning.bind(process);
process.emitWarning = (w, ...r) => { if (!String(w).includes('Ed25519 Web Crypto')) _emit(w, ...r); };

const RPC = process.env.SOLANA_RPC || 'https://api.mainnet-beta.solana.com';
const KEY = process.env.SOLANA_KEY || './id.json';
const die = (m) => { console.error(m); process.exit(1); };
const sol = (lamports) => (Number(lamports) / 1e9).toLocaleString(undefined, { maximumFractionDigits: 9 });

async function loadSigner() {
  if (!fs.existsSync(KEY)) die(`No keyfile at ${KEY} — run: node wallet.mjs new`);
  const bytes = new Uint8Array(JSON.parse(fs.readFileSync(KEY, 'utf8')));
  if (bytes.length !== 64) die(`${KEY} is not a 64-byte secret key`);
  return createKeyPairSignerFromBytes(bytes);
}
async function balanceSol(addr) {
  const { value } = await createSolanaRpc(RPC).getBalance(address(addr)).send();
  return sol(value);
}

const cmd = process.argv[2];
try {
  if (cmd === 'new') {
    if (fs.existsSync(KEY)) die(`Refusing to overwrite existing ${KEY}`);
    const kp = await crypto.subtle.generateKey('Ed25519', true, ['sign', 'verify']);
    const pkcs8 = new Uint8Array(await crypto.subtle.exportKey('pkcs8', kp.privateKey));
    const seed = pkcs8.slice(pkcs8.length - 32);           // Ed25519 PKCS8 tail = 32-byte seed
    const pub = new Uint8Array(await crypto.subtle.exportKey('raw', kp.publicKey));
    const secret = new Uint8Array(64); secret.set(seed, 0); secret.set(pub, 32);
    fs.writeFileSync(KEY, JSON.stringify(Array.from(secret)));
    fs.chmodSync(KEY, 0o600);
    const signer = await createKeyPairSignerFromBytes(secret);   // round-trip validates the bytes
    console.log(`created ${KEY}\naddress: ${signer.address}`);
  } else if (cmd === 'show') {
    const s = await loadSigner();
    console.log(`address: ${s.address}\nbalance: ${await balanceSol(s.address)} SOL   (${RPC})`);
  } else if (cmd === 'address') {
    console.log((await loadSigner()).address);
  } else if (cmd === 'balance') {
    const who = process.argv[3] || die('usage: node wallet.mjs balance <pubkey>');
    console.log(`${who}: ${await balanceSol(who)} SOL   (${RPC})`);
  } else {
    console.log('usage: node wallet.mjs <new|show|address|balance <pubkey>>');
    process.exit(cmd ? 1 : 0);
  }
} catch (e) { die(`error: ${e.message}`); }

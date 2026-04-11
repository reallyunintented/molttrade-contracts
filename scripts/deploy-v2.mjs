#!/usr/bin/env node

import { randomBytes } from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { createPublicClient, createWalletClient, defineChain, getAddress, http } from "viem";
import { privateKeyToAccount } from "viem/accounts";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, "..");

const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";
const PRIVATE_KEY_REGEX = /^0x[0-9a-fA-F]{64}$/;
const ADDRESS_REGEX = /^0x[0-9a-fA-F]{40}$/;

const DEFAULT_MANIFEST_PATH = path.join(repoRoot, "molttx.manifest.json");
const DEFAULT_FRONTEND_ENV_PATH = path.join(repoRoot, "generated/frontend.env");
const DEFAULT_NETWORK_ENV_PATH = path.join(repoRoot, "generated/network.env");
const DEFAULT_RELAYER_ENV_PATH = path.join(repoRoot, "generated/relayer.env");

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    printHelp();
    return;
  }

  const rpcUrl = requiredString(args, "rpc-url", process.env.RPC_URL);
  const chainId = numberOption(args, "chain-id", process.env.CHAIN_ID ?? "8453");
  const deployerPrivateKey = requiredPrivateKey(
    args,
    "deployer-private-key",
    process.env.DEPLOYER_PRIVATE_KEY,
  );
  const networkName = stringOption(args, "network-name", process.env.NETWORK_NAME)
    ?? inferNetworkName(chainId);
  const settlementOwner =
    stringOption(args, "settlement-owner", process.env.SETTLEMENT_OWNER)
    ?? privateKeyToAccount(deployerPrivateKey).address;
  const initialFeeBps = numberOption(args, "initial-fee-bps", process.env.INITIAL_FEE_BPS ?? "0");
  const initialFeeRecipient =
    stringOption(args, "initial-fee-recipient", process.env.INITIAL_FEE_RECIPIENT)
    ?? ZERO_ADDRESS;
  const manifestPath =
    stringOption(args, "manifest-path", process.env.MANIFEST_PATH) ?? DEFAULT_MANIFEST_PATH;
  const frontendUrl = stringOption(args, "frontend-url", process.env.FRONTEND_URL);
  const frontendOrigin =
    stringOption(args, "frontend-origin", process.env.FRONTEND_ORIGIN) ?? frontendUrl;
  const networkUrl = stringOption(args, "network-url", process.env.NETWORK_URL);
  const relayerUrl = stringOption(args, "relayer-url", process.env.RELAYER_URL);
  const frontendEnvPath =
    stringOption(args, "frontend-env-path", process.env.FRONTEND_ENV_PATH)
    ?? DEFAULT_FRONTEND_ENV_PATH;
  const networkEnvPath =
    stringOption(args, "network-env-path", process.env.NETWORK_ENV_PATH)
    ?? DEFAULT_NETWORK_ENV_PATH;
  const relayerEnvPath =
    stringOption(args, "relayer-env-path", process.env.RELAYER_ENV_PATH)
    ?? DEFAULT_RELAYER_ENV_PATH;
  const writeFrontendEnv = args.flags.has("write-frontend-env");
  const writeNetworkEnv = args.flags.has("write-network-env");
  const writeRelayerEnv = args.flags.has("write-relayer-env");
  const dryRun = args.flags.has("dry-run");

  const relayerPrivateKey = privateKeyOption(
    args,
    "relayer-private-key",
    process.env.RELAYER_PRIVATE_KEY,
  );
  const mmAllowlist = listOption(args, "mm-allowlist", process.env.MM_ALLOWLIST);
  const tokenAllowlist = listOption(args, "token-allowlist", process.env.TOKEN_ALLOWLIST);
  const relayerHost = stringOption(args, "relayer-host", process.env.RELAYER_HOST) ?? "0.0.0.0";
  const relayerPort = numberOption(args, "relayer-port", process.env.RELAYER_PORT ?? "3000");
  const relayerDb = stringOption(args, "relayer-db-url", process.env.RELAYER_DATABASE_URL)
    ?? "./relayer.production.db";
  const networkHost = stringOption(args, "network-host", process.env.NETWORK_HOST) ?? "0.0.0.0";
  const networkPort = numberOption(args, "network-port", process.env.NETWORK_PORT ?? "4001");
  const networkDb = stringOption(args, "network-db-url", process.env.NETWORK_DATABASE_URL)
    ?? "./network.production.db";

  if (!ADDRESS_REGEX.test(settlementOwner)) {
    throw new Error("--settlement-owner must be a valid address");
  }
  if (initialFeeBps < 0 || initialFeeBps > 100) {
    throw new Error("--initial-fee-bps must be between 0 and 100");
  }
  if (initialFeeBps > 0 && !ADDRESS_REGEX.test(initialFeeRecipient)) {
    throw new Error("--initial-fee-recipient must be a valid address when fees are enabled");
  }
  if (initialFeeBps === 0 && initialFeeRecipient !== ZERO_ADDRESS && !ADDRESS_REGEX.test(initialFeeRecipient)) {
    throw new Error("--initial-fee-recipient must be a valid address");
  }

  const relayerAuthToken =
    stringOption(args, "relayer-auth-token", process.env.RELAYER_AUTH_TOKEN)
    ?? ((writeNetworkEnv || writeRelayerEnv) ? randomBytes(32).toString("hex") : null);
  const makerAuthToken =
    stringOption(args, "maker-auth-token", process.env.MAKER_AUTH_TOKEN)
    ?? (writeRelayerEnv ? randomBytes(32).toString("hex") : null);

  if ((writeNetworkEnv || writeRelayerEnv) && !relayerAuthToken) {
    throw new Error("RELAYER_AUTH_TOKEN is required when writing network or relayer env files");
  }
  if (writeRelayerEnv && !makerAuthToken) {
    throw new Error("MAKER_AUTH_TOKEN is required when writing the relayer env file");
  }
  if (writeRelayerEnv && !relayerPrivateKey) {
    throw new Error("--relayer-private-key is required when writing the relayer env file");
  }
  if (writeRelayerEnv && mmAllowlist.length === 0) {
    throw new Error("--mm-allowlist is required when writing the relayer env file");
  }
  if (writeNetworkEnv && !frontendOrigin) {
    throw new Error("--frontend-origin or --frontend-url is required when writing the network env file");
  }
  if (writeNetworkEnv && !networkUrl) {
    throw new Error("--network-url is required when writing the network env file");
  }
  if (writeNetworkEnv && !relayerUrl) {
    throw new Error("--relayer-url is required when writing the network env file");
  }
  if (writeFrontendEnv && !networkUrl) {
    throw new Error("--network-url is required when writing the frontend env file");
  }

  const deployerAccount = privateKeyToAccount(deployerPrivateKey);
  const chain = defineChain({
    id: chainId,
    name: networkName,
    network: networkName.toLowerCase().replace(/\s+/g, "-"),
    nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
    rpcUrls: {
      default: { http: [rpcUrl] },
      public: { http: [rpcUrl] },
    },
  });

  const manifestDraft = {
    version: 2,
    generatedAt: new Date().toISOString(),
    environment: networkName,
    chain: {
      id: chainId,
      rpcUrl,
    },
    services: pruneUndefined({
      frontendUrl,
      frontendOrigin,
      networkUrl,
      relayerUrl,
    }),
    contracts: {
      deployer: deployerAccount.address,
      settlementOwner: getAddress(settlementOwner),
      initialFeeBps,
      initialFeeRecipient: getAddress(initialFeeRecipient),
    },
    outputs: pruneUndefined({
      frontendEnvPath: writeFrontendEnv ? path.relative(repoRoot, frontendEnvPath) : undefined,
      networkEnvPath: writeNetworkEnv ? path.relative(repoRoot, networkEnvPath) : undefined,
      relayerEnvPath: writeRelayerEnv ? path.relative(repoRoot, relayerEnvPath) : undefined,
    }),
  };

  if (dryRun) {
    console.log("Dry run only. No transactions broadcast, no files written.");
    console.log(JSON.stringify(manifestDraft, null, 2));
    return;
  }

  const [policyRegistryArtifact, settlementArtifact] = await Promise.all([
    loadArtifact(path.join(repoRoot, "out/PolicyRegistry.sol/PolicyRegistry.json")),
    loadArtifact(path.join(repoRoot, "out/BilateralSettlement.sol/BilateralSettlement.json")),
  ]);

  const publicClient = createPublicClient({ chain, transport: http(rpcUrl) });
  const walletClient = createWalletClient({
    account: deployerAccount,
    chain,
    transport: http(rpcUrl),
  });

  const policyRegistry = await deployContract({
    walletClient,
    publicClient,
    abi: policyRegistryArtifact.abi,
    bytecode: readBytecode(policyRegistryArtifact),
    args: [],
  });
  const settlementContract = await deployContract({
    walletClient,
    publicClient,
    abi: settlementArtifact.abi,
    bytecode: readBytecode(settlementArtifact),
    args: [policyRegistry.address],
  });

  let feeTxHash;
  if (initialFeeBps > 0) {
    feeTxHash = await walletClient.writeContract({
      account: deployerAccount,
      chain,
      address: settlementContract.address,
      abi: settlementArtifact.abi,
      functionName: "setFee",
      args: [BigInt(initialFeeBps), initialFeeRecipient],
    });
    await publicClient.waitForTransactionReceipt({ hash: feeTxHash });
  }

  let transferOwnershipTxHash;
  if (deployerAccount.address.toLowerCase() !== settlementOwner.toLowerCase()) {
    transferOwnershipTxHash = await walletClient.writeContract({
      account: deployerAccount,
      chain,
      address: settlementContract.address,
      abi: settlementArtifact.abi,
      functionName: "transferOwnership",
      args: [settlementOwner],
    });
    await publicClient.waitForTransactionReceipt({ hash: transferOwnershipTxHash });
  }

  const manifest = {
    ...manifestDraft,
    contracts: {
      ...manifestDraft.contracts,
      policyRegistry: policyRegistry.address,
      settlementContract: settlementContract.address,
      transactions: pruneUndefined({
        policyRegistryDeploy: policyRegistry.txHash,
        settlementDeploy: settlementContract.txHash,
        setFee: feeTxHash,
        transferOwnership: transferOwnershipTxHash,
      }),
    },
  };

  await writeJsonFile(manifestPath, manifest);

  if (writeFrontendEnv) {
    await writeEnvFile(frontendEnvPath, buildFrontendEnv({
      networkUrl,
      relayerUrl,
    }));
  }

  if (writeNetworkEnv) {
    await writeEnvFile(networkEnvPath, buildNetworkEnv({
      host: networkHost,
      port: networkPort,
      databaseUrl: networkDb,
      frontendOrigin,
      chainId,
      rpcUrl,
      policyRegistry: policyRegistry.address,
      settlementContract: settlementContract.address,
      relayerUrl,
      relayerAuthToken,
    }));
  }

  if (writeRelayerEnv) {
    await writeEnvFile(relayerEnvPath, buildRelayerEnv({
      host: relayerHost,
      port: relayerPort,
      databaseUrl: relayerDb,
      chainId,
      rpcUrl,
      relayerPrivateKey,
      policyRegistry: policyRegistry.address,
      settlementContract: settlementContract.address,
      relayerAuthToken,
      makerAuthToken,
      mmAllowlist,
      tokenAllowlist,
    }));
  }

  console.log("MoltTX V2 deployment complete");
  console.log(`Manifest: ${manifestPath}`);
  console.log(`PolicyRegistry: ${policyRegistry.address}`);
  console.log(`Settlement: ${settlementContract.address}`);
  if (writeFrontendEnv) {
    console.log(`Frontend env: ${frontendEnvPath}`);
  }
  if (writeNetworkEnv) {
    console.log(`Network env: ${networkEnvPath}`);
  }
  if (writeRelayerEnv) {
    console.log(`Relayer env: ${relayerEnvPath}`);
  }
}

function parseArgs(argv) {
  const flags = new Set();
  const values = new Map();

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (!arg.startsWith("--")) {
      throw new Error(`Unknown argument: ${arg}`);
    }

    const key = arg.slice(2);
    if (["help", "dry-run", "write-frontend-env", "write-network-env", "write-relayer-env"].includes(key)) {
      flags.add(key);
      continue;
    }

    const next = argv[index + 1];
    if (!next || next.startsWith("--")) {
      throw new Error(`Missing value for --${key}`);
    }
    values.set(key, next);
    index += 1;
  }

  return { flags, values, help: flags.has("help") };
}

function printHelp() {
  console.log(`Usage: node scripts/deploy-v2.mjs [options]

Required:
  --rpc-url <url>                   RPC endpoint for the target chain
  --deployer-private-key <hex>      Broadcaster private key

Optional deployment config:
  --chain-id <n>                    Chain id (default: 8453)
  --network-name <name>             Manifest label (default inferred from chain id)
  --settlement-owner <address>      Final BilateralSettlement owner
  --initial-fee-bps <n>             Initial protocol fee bps (default: 0, max: 100)
  --initial-fee-recipient <addr>    Fee recipient when fee bps > 0
  --manifest-path <path>            Output manifest path (default: ./molttx.manifest.json)

Public service manifest fields:
  --frontend-url <url>              Public frontend URL, e.g. https://molttx.com
  --frontend-origin <url>           Exact browser origin for network CORS
  --network-url <url>               Public network-service base URL
  --relayer-url <url>               Public relayer base URL

Optional env file writes:
  --write-frontend-env              Write generated/frontend.env
  --write-network-env               Write generated/network.env
  --write-relayer-env               Write generated/relayer.env
  --frontend-env-path <path>        Override frontend env path
  --network-env-path <path>         Override network env path
  --relayer-env-path <path>         Override relayer env path

Server env inputs when writing env files:
  --relayer-private-key <hex>       Required for relayer env writes
  --relayer-auth-token <hex>        Shared token for network->relayer reads (generated if omitted)
  --maker-auth-token <hex>          Relayer->maker auth token (generated if omitted)
  --mm-allowlist <csv>              Relayer market maker allowlist
  --token-allowlist <csv>           Relayer token allowlist
  --network-host <host>             Network bind host (default: 0.0.0.0)
  --network-port <n>                Network port (default: 4001)
  --network-db-url <path>           Network database path
  --relayer-host <host>             Relayer bind host (default: 0.0.0.0)
  --relayer-port <n>                Relayer port (default: 3000)
  --relayer-db-url <path>           Relayer database path

Safety / inspection:
  --dry-run                         Validate inputs and print the manifest draft only
  --help                            Show this message
`);
}

function stringOption(args, key, fallback = undefined) {
  return args.values.get(key) ?? fallback;
}

function numberOption(args, key, fallback = undefined) {
  const raw = args.values.get(key) ?? fallback;
  if (raw == null || raw === "") {
    return undefined;
  }
  const value = Number(raw);
  if (!Number.isFinite(value)) {
    throw new Error(`--${key} must be a number`);
  }
  return value;
}

function requiredString(args, key, fallback = undefined) {
  const value = stringOption(args, key, fallback);
  if (!value) {
    throw new Error(`--${key} is required`);
  }
  return value;
}

function privateKeyOption(args, key, fallback = undefined) {
  const value = stringOption(args, key, fallback);
  if (!value) {
    return null;
  }
  if (!PRIVATE_KEY_REGEX.test(value)) {
    throw new Error(`--${key} must be a 32-byte hex private key`);
  }
  return value;
}

function requiredPrivateKey(args, key, fallback = undefined) {
  const value = privateKeyOption(args, key, fallback);
  if (!value) {
    throw new Error(`--${key} is required`);
  }
  return value;
}

function listOption(args, key, fallback = undefined) {
  const raw = stringOption(args, key, fallback);
  if (!raw) return [];
  return raw
    .split(",")
    .map((value) => value.trim())
    .filter(Boolean);
}

function inferNetworkName(chainId) {
  if (chainId === 8453) return "base-mainnet";
  if (chainId === 84532) return "base-sepolia";
  return `chain-${chainId}`;
}

async function loadArtifact(artifactPath) {
  return JSON.parse(await readFile(artifactPath, "utf8"));
}

function readBytecode(artifact) {
  const bytecode = artifact?.bytecode?.object ?? artifact?.bytecode;
  if (typeof bytecode !== "string" || bytecode.length === 0) {
    throw new Error("Artifact is missing deployable bytecode");
  }
  return bytecode.startsWith("0x") ? bytecode : `0x${bytecode}`;
}

async function deployContract({ walletClient, publicClient, abi, bytecode, args }) {
  const txHash = await walletClient.deployContract({
    abi,
    bytecode,
    args,
  });
  const receipt = await publicClient.waitForTransactionReceipt({ hash: txHash });
  if (!receipt.contractAddress) {
    throw new Error("Deployment receipt did not include a contract address");
  }
  return {
    address: receipt.contractAddress,
    txHash,
  };
}

async function writeJsonFile(filePath, value) {
  await mkdir(path.dirname(filePath), { recursive: true });
  await writeFile(filePath, `${JSON.stringify(value, null, 2)}\n`, "utf8");
}

async function writeEnvFile(filePath, lines) {
  await mkdir(path.dirname(filePath), { recursive: true });
  await writeFile(filePath, `${lines.join("\n")}\n`, "utf8");
}

function buildFrontendEnv({ networkUrl, relayerUrl }) {
  const lines = [
    "# Generated by scripts/deploy-v2.mjs",
    "# Keep relayer auth tokens out of Vite env; browser bundles are public.",
    `VITE_NETWORK_URL=${networkUrl}`,
  ];
  if (relayerUrl) {
    lines.push(`VITE_RELAYER_URL=${relayerUrl}`);
  }
  return lines;
}

function buildNetworkEnv({
  host,
  port,
  databaseUrl,
  frontendOrigin,
  chainId,
  rpcUrl,
  policyRegistry,
  settlementContract,
  relayerUrl,
  relayerAuthToken,
}) {
  return [
    "# Generated by scripts/deploy-v2.mjs",
    `HOST=${host}`,
    `PORT=${port}`,
    `DATABASE_URL=${databaseUrl}`,
    `ORIGIN=${frontendOrigin}`,
    "CHALLENGE_TTL_SECONDS=300",
    "SESSION_TTL_SECONDS=604800",
    `CHAIN_ID=${chainId}`,
    `RPC_URL=${rpcUrl}`,
    `POLICY_REGISTRY=${policyRegistry}`,
    `SETTLEMENT_CONTRACT=${settlementContract}`,
    `RELAYER_URL=${relayerUrl}`,
    `RELAYER_AUTH_TOKEN=${relayerAuthToken}`,
  ];
}

function buildRelayerEnv({
  host,
  port,
  databaseUrl,
  chainId,
  rpcUrl,
  relayerPrivateKey,
  policyRegistry,
  settlementContract,
  relayerAuthToken,
  makerAuthToken,
  mmAllowlist,
  tokenAllowlist,
}) {
  const lines = [
    "# Generated by scripts/deploy-v2.mjs",
    `HOST=${host}`,
    `PORT=${port}`,
    `DATABASE_URL=${databaseUrl}`,
    `RPC_URL=${rpcUrl}`,
    `RELAYER_PRIVATE_KEY=${relayerPrivateKey}`,
    `SETTLEMENT_CONTRACT=${settlementContract}`,
    `POLICY_REGISTRY=${policyRegistry}`,
    `CHAIN_ID=${chainId}`,
    `MM_ALLOWLIST=${mmAllowlist.join(",")}`,
    `RELAYER_AUTH_TOKEN=${relayerAuthToken}`,
    `MAKER_AUTH_TOKEN=${makerAuthToken}`,
    "CLOCK_GRACE_SECONDS=30",
    "FINALITY_BLOCKS=2",
    "GAS_BUMP_THRESHOLD_MS=15000",
    "TX_MAX_LIFETIME_MS=300000",
    "RFQ_RATE_LIMIT_WINDOW_SECS=60",
    "RFQ_RATE_LIMIT_MAX_PER_WINDOW=10",
  ];
  if (tokenAllowlist.length > 0) {
    lines.splice(8, 0, `TOKEN_ALLOWLIST=${tokenAllowlist.join(",")}`);
  }
  return lines;
}

function pruneUndefined(value) {
  return Object.fromEntries(
    Object.entries(value).filter(([, candidate]) => candidate !== undefined && candidate !== null),
  );
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : error);
  process.exit(1);
});

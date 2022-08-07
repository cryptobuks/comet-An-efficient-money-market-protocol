import { Contract } from 'ethers';
import { HardhatRuntimeEnvironment as HRE } from 'hardhat/types';

import { Cache } from './Cache';
import {
  Ctx,
  AliasTemplate,
  AliasRender,
  RelationConfigMap,
  RelationConfig,
  RelationInnerConfig,
  aliasTemplateKey,
  getFieldKey,
  readAlias,
  readField,
} from './RelationConfig';
import { Address, Alias, BuildFile } from './Types';
import { Aliases } from './Aliases';
import { Proxies } from './Proxies';
import { ContractMap } from './ContractMap';
import { Roots } from './Roots';
import { asArray, debug, getEthersContract, mergeABI } from './Utils';
import { fetchAndCacheContract, readAndCacheContract } from './Import';

export interface Spider {
  aliases: Aliases;
  proxies: Proxies;
}

interface Build {
  buildFile: BuildFile;
  contract: Contract;
}

interface DiscoverNode {
  address: Address;
  aliasRender: AliasRender;
}

function maybeStore(alias: Alias, address: Address, into: Aliases | Proxies): boolean {
  const maybeExists = into.get(alias);
  if (maybeExists) {
    if (maybeExists === address) {
      return false;
    } else {
      throw new Error(`Had ${alias} -> ${maybeExists}, not ${address}`)
    }
  } else {
    into.set(alias, address);
    return true;
  }
}

async function discoverNodes(
  contract: Contract,
  context: Ctx,
  config: RelationInnerConfig,
  defaultKeyAndTemplate: string
): Promise<DiscoverNode[]> {
  const addresses = await readField(contract, getFieldKey(config, defaultKeyAndTemplate), context);
  const templates = config.alias ? asArray(config.alias) : [defaultKeyAndTemplate];
  return addresses.map((address, i) => ({
    address,
    aliasRender: { template: templates[i % templates.length], i },
  }));
}

async function isContract(hre: HRE, address: string) {
  return await hre.ethers.provider.getCode(address) !== '0x';
}

async function localBuild(cache: Cache, hre: HRE, artifact: string, address: Address): Promise<Build> {
  const buildFile = await readAndCacheContract(cache, hre, artifact, address);
  const contract = getEthersContract(address, buildFile, hre);
  return { buildFile, contract };
}

async function remoteBuild(cache: Cache, hre: HRE, network: string, address: Address): Promise<Build> {
  const buildFile = await fetchAndCacheContract(cache, network, address);
  const contract = getEthersContract(address, buildFile, hre);
  return { buildFile, contract };
}

async function crawl(
  cache: Cache,
  network: string,
  hre: HRE,
  relations: RelationConfigMap,
  node: DiscoverNode,
  context: Ctx,
  aliases: Aliases,
  proxies: Proxies,
  contracts: ContractMap,
): Promise<Alias> {
  const { aliasRender, address } = node;
  const { template: aliasTemplate } = aliasRender;
  debug(`Crawling ${address}...`, aliasRender);

  async function maybeProcess(alias: Alias, build: Build, config: RelationConfig): Promise<Alias> {
    if (maybeStore(alias, address, aliases)) {
      debug(`Processing ${address}...`, alias);
      let contract = build.contract;

      if (config.delegates) {
        const implAliasTemplate = `${alias}:implementation`;
        const implNodes = await discoverNodes(contract, context, config.delegates, implAliasTemplate);
        for (const implNode of implNodes) {
          const implAlias = await crawl(
            cache,
            network,
            hre,
            relations,
            implNode,
            context,
            aliases,
            proxies,
            contracts,
          );
          const implContract = contracts.get(implAlias);
          if (!implContract) {
            throw new Error(`Failed to crawl ${implAlias} at ${implNode.address}`);
          }

          // Extend the contract ABI w/ the delegate
          contract = new hre.ethers.Contract(
            address,
            mergeABI(
              implContract.interface.format('json'),
              contract.interface.format('json')
            ),
            hre.ethers.provider
          );

          // TOOD: is Proxies necessary? limiting us to one delegate here really
          maybeStore(alias, implNode.address, proxies);
        }
      }

      // Add the alias in place to the absolute contracts
      contracts.set(alias, contract);

      if (config.relations) {
        for (const [subKey, subConfig] of Object.entries(config.relations)) {
          const subNodes = await discoverNodes(contract, context, subConfig, subKey);
          for (const subNode of subNodes) {
            const subAlias = await crawl(
              cache,
              network,
              hre,
              relations,
              subNode,
              context,
              aliases,
              proxies,
              contracts,
            );

            // Add the aliasTemplate in place to the relative context
            const subContract = contracts.get(subAlias);
            if (subContract) {
              (context[subKey] = context[subKey] || []).push(subContract);
            }
          }
        }
      }

      debug(`Crawled ${address}:`, alias);
    } else {
      debug(`Already processed ${address}...`, alias);
    }
    return alias;
  }

  const aliasConfig = relations[aliasTemplateKey(aliasTemplate)];
  if (aliasConfig) {
    if (!await isContract(hre, address)) {
      throw new Error(`Found config for '${aliasTemplate}' but no contract at ${address}`);
    }
    if (aliasConfig.artifact) {
      const build = await localBuild(cache, hre, aliasConfig.artifact, address);
      const alias = await readAlias(build.contract, aliasRender, context);
      return maybeProcess(alias, build, aliasConfig);
    } else {
      const build = await remoteBuild(cache, hre, network, address);
      const alias = await readAlias(build.contract, aliasRender, context);
      return maybeProcess(alias, build, aliasConfig);
    }
  } else {
    if (await isContract(hre, address)) {
      const build = await remoteBuild(cache, hre, network, address);
      const alias = await readAlias(build.contract, aliasRender, context);
      const contractConfig = relations[build.buildFile.contract] || {};
      return maybeProcess(alias, build, contractConfig);
    } else {
      const alias = await readAlias(undefined, aliasRender, context);
      return maybeStore(alias, address, aliases), alias;
    }
  }
}

export async function spider(
  cache: Cache,
  network: string,
  hre: HRE,
  relations: RelationConfigMap,
  roots: Roots,
): Promise<Spider> {
  const discovered: DiscoverNode[] = [...roots.entries()].map(([alias, address]) => ({
    aliasRender: { template: alias, i: 0 },
    address,
  }));
  const context = {};
  const aliases = new Map();
  const proxies = new Map();
  const contracts = new Map();

  for (const [alias, address] of roots) {
    await crawl(
      cache,
      network,
      hre,
      relations,
      { aliasRender: { template: alias, i: 0 }, address },
      context,
      aliases,
      proxies,
      contracts,
    );
  }

  return { aliases, proxies };
}

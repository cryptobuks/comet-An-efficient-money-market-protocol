import { scenario } from './context/CometContext';
import { expect } from 'chai';
import { constants, utils } from 'ethers';
import { COMP_WHALES } from "../src/deploy";
import { impersonateAddress } from '../plugins/scenario/utils';
import { isBridgedDeployment, fastL2GovernanceExecute } from './utils';

const FX_ROOT_GOERLI = '0x3d1d3E34f7fB6D26245E6640E1c50710eFFf15bA';

scenario(
  'execute Mumbai governance proposal',
  {
    filter: async (ctx) => ctx.world.base.network === 'mumbai'
  },
  async (_properties, _context, world) => {
    const governanceDeploymentManager = world.auxiliaryDeploymentManager;
    if (!governanceDeploymentManager) {
      throw new Error("cannot execute governance without governance deployment manager");
    }

    const l2Timelock = await world.deploymentManager.contract('timelock');
    if (!l2Timelock) {
      throw new Error("deployment missing timelock");
    }

    const bridgeReceiver = await world.deploymentManager.contract('bridgeReceiver');

    // l2 proposal
    const fiveDaysInSeconds = 5 * 24 * 60 * 60;
    const encodedL2Data = utils.defaultAbiCoder.encode(
      ['address[]', 'uint256[]', 'string[]', 'bytes[]'],
      [
        [l2Timelock?.address],
        [0],
        ["setDelay(uint256)"],
        [
          utils.defaultAbiCoder.encode(['uint'], [fiveDaysInSeconds])
        ]
      ]
    );

    // l1 proposal -> fxRoot.sendMessageToChild(fxChildTunnel, l2Data)
    const sendMessageToChildCalldata = utils.defaultAbiCoder.encode(
      ['address', 'bytes'],
      [bridgeReceiver?.address, encodedL2Data]
    );

    const bridgeDeploymentManager = world.deploymentManager;
    const proposer = await impersonateAddress(governanceDeploymentManager, COMP_WHALES[0]);

    // check delay before
    console.log(`await l2Timelock?.delay(): ${await l2Timelock?.delay()}`);
    expect(await l2Timelock?.delay()).to.eq(2 * 24 * 60 * 60);

    await fastL2GovernanceExecute(
      governanceDeploymentManager,
      bridgeDeploymentManager,
      proposer,
      [FX_ROOT_GOERLI],
      [0],
      ["sendMessageToChild(address,bytes)"],
      [sendMessageToChildCalldata]
    );

    // check delay after
    console.log(`await l2Timelock?.delay(): ${await l2Timelock?.delay()}`);
    expect(await l2Timelock?.delay()).to.eq(fiveDaysInSeconds);
  }
);

scenario(
  'upgrade Comet implementation and initialize',
  {
    filter: async (ctx) => !isBridgedDeployment(ctx)
  },
  async ({ comet, configurator, proxyAdmin }, context, world) => {
    // For this scenario, we will be using the value of LiquidatorPoints.numAbsorbs for address ZERO to test that initialize has been called
    expect((await comet.liquidatorPoints(constants.AddressZero)).numAbsorbs).to.be.equal(0);

    // Deploy new version of Comet Factory
    const dm = world.deploymentManager;
    const cometModifiedFactory = await dm.deploy('cometFactory', 'test/CometModifiedFactory.sol', [], true);

    // Execute a governance proposal to:
    // 1. Set the new factory address in Configurator
    // 2. Deploy and upgrade to the new implementation of Comet
    // 3. Call initialize(address) on the new version of Comet
    const setFactoryCalldata = utils.defaultAbiCoder.encode(['address', 'address'], [comet.address, cometModifiedFactory.address]);
    const deployAndUpgradeToCalldata = utils.defaultAbiCoder.encode(['address', 'address'], [configurator.address, comet.address]);
    const initializeCalldata = utils.defaultAbiCoder.encode(['address'], [constants.AddressZero]);
    await context.fastGovernanceExecute(
      [configurator.address, proxyAdmin.address, comet.address],
      [0, 0, 0],
      ['setFactory(address,address)', 'deployAndUpgradeTo(address,address)', 'initialize(address)'],
      [setFactoryCalldata, deployAndUpgradeToCalldata, initializeCalldata]
    );

    // LiquidatorPoints.numAbsorbs for address ZERO should now be set as UInt32.MAX
    expect((await comet.liquidatorPoints(constants.AddressZero)).numAbsorbs).to.be.equal(2 ** 32 - 1);
  }
);

scenario(
  'upgrade Comet implementation and initialize using deployUpgradeToAndCall',
  {
    filter: async (ctx) => !isBridgedDeployment(ctx)
  },
  async ({ comet, configurator, proxyAdmin }, context, world) => {
    // For this scenario, we will be using the value of LiquidatorPoints.numAbsorbs for address ZERO to test that initialize has been called
    expect((await comet.liquidatorPoints(constants.AddressZero)).numAbsorbs).to.be.equal(0);

    // Deploy new version of Comet Factory
    const dm = world.deploymentManager;
    const cometModifiedFactory = await dm.deploy(
      'cometFactory',
      'test/CometModifiedFactory.sol',
      [],
      true
    );

    // Execute a governance proposal to:
    // 1. Set the new factory address in Configurator
    // 2. DeployUpgradeToAndCall the new implementation of Comet
    const setFactoryCalldata = utils.defaultAbiCoder.encode(["address", "address"], [comet.address, cometModifiedFactory.address]);
    const modifiedComet = (await dm.hre.ethers.getContractFactory('CometModified')).attach(comet.address);
    const initializeCalldata = (await modifiedComet.populateTransaction.initialize(constants.AddressZero)).data;
    const deployUpgradeToAndCallCalldata = utils.defaultAbiCoder.encode(["address", "address", "bytes"], [configurator.address, comet.address, initializeCalldata]);

    await context.fastGovernanceExecute(
      [configurator.address, proxyAdmin.address],
      [0, 0],
      ["setFactory(address,address)", "deployUpgradeToAndCall(address,address,bytes)"],
      [setFactoryCalldata, deployUpgradeToAndCallCalldata]
    );

    // LiquidatorPoints.numAbsorbs for address ZERO should now be set as UInt32.MAX
    expect((await comet.liquidatorPoints(constants.AddressZero)).numAbsorbs).to.be.equal(2 ** 32 - 1);
  }
);

scenario(
  'upgrade Comet implementation and call new function',
  {
    filter: async (ctx) => !isBridgedDeployment(ctx)
  },
  async ({ comet, configurator, proxyAdmin, actors }, context, world) => {
    const { signer } = actors;

    // Deploy new version of Comet Factory
    const dm = world.deploymentManager;
    const cometModifiedFactory = await dm.deploy('cometFactory', 'test/CometModifiedFactory.sol', [], true);

    // Upgrade Comet implementation
    const setFactoryCalldata = utils.defaultAbiCoder.encode(['address', 'address'], [comet.address, cometModifiedFactory.address]);
    const deployAndUpgradeToCalldata = utils.defaultAbiCoder.encode(['address', 'address'], [configurator.address, comet.address]);
    await context.fastGovernanceExecute(
      [configurator.address, proxyAdmin.address],
      [0, 0],
      ['setFactory(address,address)', 'deployAndUpgradeTo(address,address)'],
      [setFactoryCalldata, deployAndUpgradeToCalldata]
    );

    const CometModified = await dm.hre.ethers.getContractFactory('CometModified');
    const modifiedComet = CometModified.attach(comet.address).connect(signer.signer);

    // Call new functions on Comet
    await modifiedComet.initialize(constants.AddressZero);
    expect(await modifiedComet.newFunction()).to.be.equal(101n);
  }
);

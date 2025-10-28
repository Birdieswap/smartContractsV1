# 🦜 Birdieswap V1 (Preview Repository)

> **Disclaimer:**  
> This repository is a **temporary public preview** of the Birdieswap V1 smart contract system.  
> It has been **selectively published** for **potential investors, grant program reviewers, and strategic partners** to review the core architecture and technical design of the protocol.

Please note that this repository does **not represent the final production codebase**.  
A separate, updated repository containing the finalized deployment version will be made public after mainnet launch.

---

## Overview

**Birdieswap** is a decentralized liquidity and routing protocol designed to optimize swap execution and liquidity efficiency across multiple strategies.  

The architecture emphasizes **modularity**, **security**, and **upgradeability** through a layered system of governance and execution contracts.

This preview showcases the essential smart contracts that define the protocol’s structure and interaction model.

---

## Core Components

Birdieswap V1 follows a modular architecture composed of distinct layers — **Routing**, **Vault & Strategy**, **Staking & Wrapper**, and **Governance & Infrastructure**.  

Each component operates independently but interacts through standardized interfaces, ensuring security isolation and upgrade flexibility.

---

### Routing Layer
| Contract              | Description                                                                                                                                                                        |
| --------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `BirdieswapWrapperV1` | Wrapper contract providing user-friendly interfaces for deposit, withdrawal, and multi-step operations with native ETH. Acts as an interaction layer between users and the router. |
| `BirdieswapRouterV1`  | The central routing contract responsible for coordinating user operations, managing vault/strategy selections, and executing swaps and liquidity actions across modules.           |

---

### Vault & Strategy Layer
| Contract                     | Description                                                                                                                              |
| ---------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| `BirdieswapSingleVaultV1`    | Vault implementation managing single-asset strategies. Handles user deposits, share accounting, and yield tracking.                      |
| `BirdieswapSingleStrategyV1` | Strategy module optimized for single-token liquidity operations (e.g., staking or lending-based yields).                                 |
| `BirdieswapDualVaultV1`      | Vault implementation for paired-asset strategies (e.g., Uniswap V3-like LP positions). Manages position accounting and fee distribution. |
| `BirdieswapDualStrategyV1`   | Dual-asset strategy contract integrating with Uniswap V3 pools or similar AMM structures for liquidity provision and optimization.       |

---

### Staking Layer
| Contract              | Description                                                                                                            |
| --------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| `BirdieswapStakingV1` | Protocol staking module that allows users to stake governance or liquidity tokens to earn rewards or governance power. |

---

### Governance & Infrastructure Layer
| Contract                    | Description                                                                                                     |
| --------------------------- | --------------------------------------------------------------------------------------------------------------- |
| `BirdieswapRoleRouterV1`    | Manages protocol-wide role-based permissions and access control routing across modules.                         |
| `BirdieswapEventRelayerV1`  | Handles event forwarding and broadcasting to off-chain systems, analytics, or monitoring services.              |
| `BirdieswapStorageV1`       | Central storage contract maintaining protocol configurations, addresses, and operational states.                |
| `BirdieswapConfigV1`        | Defines protocol-level constants, parameters, and configuration values shared across all components.            |
| `BirdieswapRoleSignatureV1` | Provides role-based signature validation and authorization utilities used by governance and automation systems. |

---

## Dependencies

This project uses **Foundry** as its development framework.

```
forge install OpenZeppelin/openzeppelin-contracts@v5.4.0
forge install Uniswap/v3-core@v1.0.1
forge install Uniswap/v3-periphery@v1.4.4
```


---

## Current Status

- **Stage:** Development (Pre-Mainnet) - Being tested on testnet
- **Purpose:** Limited disclosure for grant/investor review
- **Audit:** Internal security review ongoing
- **Deployment:** Testnet evaluation phase
- **Next:** Integration of timelock governance and multi-signature control

---

## License & Usage

All materials in this repository are shared **for review and informational purposes only**.  
Commercial use, redistribution, or modification requires prior written permission from the Birdieswap team.

---

## Important Note

This repository represents only a **partial and temporary release** of the Birdieswap codebase.  
Additional modules, deployment scripts, and configuration details have been intentionally omitted for operational and security reasons.  

A finalized audited version will be released under a separate repository following mainnet deployment.

---

## Contact

- **Email:** [contact@Birdieswap.com](mailto:contact@Birdieswap.com)  
- **X:** [@Birdieswap](https://x.com/Birdieswap)
- **Website:** https://Birdieswap.com (full functional website is coming soon)

---

**© 2025 Birdieswap Protocol. All rights reserved.**

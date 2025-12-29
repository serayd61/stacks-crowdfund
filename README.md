# Stacks Crowdfund

Decentralized crowdfunding platform on Stacks blockchain. Create campaigns, raise STX, and build community-funded projects.

## Features

- **Create Campaigns**: Set goal, duration, and description
- **Contribute STX**: Back projects you believe in
- **Automatic Refunds**: Get refunds if goal not reached
- **Milestone Tracking**: Break projects into deliverables
- **Creator/Backer Stats**: On-chain reputation system
- **Low Fees**: 2% platform fee on successful campaigns

## Campaign Lifecycle

```
┌─────────────────────────────────────────────────────────────────┐
│                     CAMPAIGN LIFECYCLE                           │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌────────────┐    ┌────────────┐    ┌────────────┐             │
│  │   CREATE   │───▶│   ACTIVE   │───▶│    END     │             │
│  │  Campaign  │    │ Collecting │    │  Deadline  │             │
│  └────────────┘    └────────────┘    └─────┬──────┘             │
│                                            │                     │
│                    ┌───────────────────────┴───────────┐        │
│                    │                                    │        │
│                    ▼                                    ▼        │
│            ┌────────────┐                      ┌────────────┐   │
│            │  SUCCESS   │                      │   FAILED   │   │
│            │ Goal Met   │                      │ Goal Missed│   │
│            └─────┬──────┘                      └──────┬─────┘   │
│                  │                                    │         │
│                  ▼                                    ▼         │
│            ┌────────────┐                      ┌────────────┐   │
│            │   CLAIM    │                      │   REFUND   │   │
│            │   Funds    │                      │  Backers   │   │
│            └────────────┘                      └────────────┘   │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

## Smart Contract Functions

### Campaign Management
```clarity
(create-campaign (title) (description) (goal) (duration))
(extend-deadline (campaign-id) (additional-blocks))
(update-description (campaign-id) (new-description))
```

### Contributions
```clarity
(contribute (campaign-id) (amount))
```

### Claiming
```clarity
(claim-funds (campaign-id))      ;; Creator claims on success
(enable-refunds (campaign-id))   ;; Creator enables refunds on failure
(claim-refund (campaign-id))     ;; Backer claims refund
```

### Read-Only
```clarity
(get-campaign (campaign-id))
(get-contribution (campaign-id) (contributor))
(is-campaign-active (campaign-id))
(is-campaign-successful (campaign-id))
(get-progress-percentage (campaign-id))
(get-creator-stats (creator))
(get-backer-stats (backer))
(get-platform-stats)
```

## Usage Examples

### Create a Campaign
```clarity
;; Create campaign: 1000 STX goal, ~30 days duration (4320 blocks)
(contract-call? .crowdfund create-campaign 
  u"Build a Stacks DEX"
  u"We're building a decentralized exchange on Stacks with advanced features..."
  u1000000000
  u4320)
```

### Back a Campaign
```clarity
;; Contribute 50 STX
(contract-call? .crowdfund contribute u0 u50000000)
```

### Claim Funds (Creator)
```clarity
;; After campaign ends successfully
(contract-call? .crowdfund claim-funds u0)
```

### Get Refund (Backer)
```clarity
;; If campaign failed
(contract-call? .crowdfund enable-refunds u0)  ;; Creator enables
(contract-call? .crowdfund claim-refund u0)     ;; Backer claims
```

## Fee Structure

| Event | Fee |
|-------|-----|
| Create Campaign | Free |
| Contribute | Free |
| Successful Claim | 2% |
| Refund | Free |

## Stats & Reputation

### Creator Stats
- Campaigns created
- Campaigns successful
- Total raised

### Backer Stats
- Campaigns backed
- Total contributed

## Security

- Only campaign owner can claim funds
- Refunds only available for failed campaigns
- Funds locked until deadline
- Transparent on-chain accounting

## Installation

```bash
git clone https://github.com/serayd61/stacks-crowdfund.git
cd stacks-crowdfund
clarinet test
```

## Future Features

- [ ] Milestone-based fund release
- [ ] NFT rewards for backers
- [ ] Early bird pricing
- [ ] Recurring contributions
- [ ] Social sharing integration

## License

MIT License

## Links

- [Stacks Documentation](https://docs.stacks.co/)
- [Clarity Language](https://docs.stacks.co/clarity)


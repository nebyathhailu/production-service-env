# ECS on Fargate — Dependency Graph (Gate 1)

This is the visual dependency graph for Phase 1. Each arrow means "must exist before."

```mermaid
graph TD
    A[IAM Identity] --> B[Assigned Region]
    B --> C[Default VPC]
    C --> D[Default Subnets<br/>2 Availability Zones]
    D --> E[Security Groups]
    E --> F[ECR Repositories]
    F --> G[ECS Cluster]
    G --> H[Task Definitions]
    H --> I[ECS Services]
    I --> J[Service Connect Namespace]
    J --> K[Target Group]
    K --> L[Application Load Balancer]
    L --> M[DNS]

    N[CloudWatch Logs] -.attached to.-> H
    N -.attached to.-> I
    O[CodeConnections] -.attached to.-> P[CodePipeline]
    P -.attached to.-> Q[CodeBuild]
    Q -.attached to.-> R[ECS Deployment]
    R -.triggers new revision of.-> H

    style A fill:#f9f,stroke:#333
    style M fill:#9f9,stroke:#333
    style N fill:#ffd,stroke:#333
    style O fill:#ffd,stroke:#333
    style P fill:#ffd,stroke:#333
    style Q fill:#ffd,stroke:#333
    style R fill:#ffd,stroke:#333
```

## Reading this diagram

- **Solid arrows** = hard dependency chain (top to bottom). Each box cannot function until
  everything above it exists.
- **Dashed arrows** = supporting/automation systems that attach onto the main chain rather than
  sitting inside it — logging attaches to task definitions and services; the CI/CD chain
  (CodeConnections → CodePipeline → CodeBuild) ultimately produces new task definition revisions
  that ECS deploys.
- **Pink box (IAM Identity)** = the absolute floor; nothing happens without this.
- **Green box (DNS)** = the end of the chain; this is what a real user actually types/hits.
- **Yellow boxes** = the "Ship It" automation layer, separate from the "Host It / Wire It" chain
  above it, but ultimately feeding back into Task Definitions when a new deployment happens.

## Service-level detail (your three services + platform, mapped onto the graph)

```mermaid
graph LR
    subgraph Internet
        User[User Request]
    end

    subgraph AWS["AWS - devops-g&lt;n&gt;"]
        ALB[Application Load Balancer<br/>devops-g-n--alb]
        TG[Target Group<br/>ride-api only]

        subgraph ECS["ECS Cluster - devops-g&lt;n&gt;-cluster"]
            RideAPI["ride-api<br/>Fargate task<br/>Person 1"]
            Matching["matching-service<br/>Fargate task<br/>Person 2"]
            Dispatch["dispatch-service<br/>Fargate task<br/>Person 3"]
        end

        SC[Service Connect namespace<br/>group-n-.internal]
    end

    User -->|":80"| ALB
    ALB --> TG
    TG -->|":3001"| RideAPI
    RideAPI <-.->|registered in| SC
    Matching <-.->|registered in| SC
    Dispatch <-.->|registered in| SC
    RideAPI -->|":3002 allowed"| Matching
    Matching -->|":3003 allowed"| Dispatch
    RideAPI -.->|":3003 DENIED"| Dispatch

    style RideAPI fill:#bde,stroke:#333
    style Matching fill:#bde,stroke:#333
    style Dispatch fill:#bde,stroke:#333
    style ALB fill:#9f9,stroke:#333
```

This second diagram is the one worth showing live in the demo — it makes the "only ride-api is
public, matching-service and dispatch-service are internal-only, and ride-api cannot reach
dispatch-service directly" rule visually obvious at a glance.

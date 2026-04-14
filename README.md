# Skywave Airlines Agent

An Agentforce agent demo that helps customers search flights, book trips, manage bookings, and handle support cases for a fictional airline.

## Prerequisites

- [Salesforce CLI (`sf`)](https://developer.salesforce.com/tools/salesforcecli) installed
- Authenticated into a DevHub org (`sf org login web --set-default-dev-hub`)

## Getting Started

1. Run the org init script:

   ```sh
   sh orgInit.sh
   ```

   This creates a scratch org, sets up an Einstein Agent user, deploys the project, and opens Salesforce Setup in your browser.

2. **Set up Data Cloud** — Data Cloud takes ~20 minutes to activate after the org is created. Monitor progress in **Setup > Data Cloud Setup Home**. Once active, go to **Setup > Agentforce Data Library** and create a new Data Library.

3. In Salesforce, click the **App Launcher** (grid icon, top-left) and search for **Agentforce Studio**.

4. Click **Skywave Airlines Agent**.

5. Click **Preview**.

6. You’ll be prompted to assign a user record. Click **Select User**.

7. Click the search text box — there will be one user available. Select it.

8. Click **Save**.

9. Click **Preview** again. The agent chat window will open.

10. Try it out with a question like:

   > Find me a flight from SEA to JFK on Sunday

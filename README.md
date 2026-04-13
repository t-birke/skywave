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

2. In Salesforce, click the **App Launcher** (grid icon, top-left) and search for **Agentforce Studio**.

3. Click **Skywave Airlines Agent**.

4. Click **Preview**.

5. You’ll be prompted to assign a user record. Click **Select User**.

6. Click the search text box — there will be one user available. Select it.

7. Click **Save**.

8. Click **Preview** again. The agent chat window will open.

9. Try it out with a question like:

   > Find me a flight from SEA to JFK on Sunday

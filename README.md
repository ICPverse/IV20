# IV20
This is the code for IV20, the token guidelines for Game and Metaverse project tokens, aiming to build on the Internet Computer.

Note: IV20 is a token guideline, not a token standard.

IV20 is built on top on DIP20, created by the Psychedelic Team.

IV20 is compatible with both IS20 and DIP20 tokens. All IS20 / DIP20 tokens are not IV20, but all IV20 tokens are DIP20 / IS20.

The following additional features are implemented in addition to standard DIP20 functionality:
1. External Integration
2. Token Locking or Vesting
3. Staking-like Functionality
4. Dividend Distribution to HODLers
5. Voting Function for DAO behavior

The code is in Motoko, and creating the additional functions, variables, and types should make an EXT token also comply with IV20 guidelines.

This is Open Source Code, and not meant to be distributed commercially by any party.

The ICPverse Team invites all members of the IC Developer Ecosystem to suggest more functionalities and features to add to subsequent releases.

Instructions for Use:

cd IV20

dfx start --background

dfx deploy token --argument '("","TOKENNAME","TKN",3,10000000, principal "<your-principal-here>",50)'


import type { Principal } from '@dfinity/principal';
export interface Metadata {
  'fee' : bigint,
  'decimals' : number,
  'owner' : Principal,
  'logo' : string,
  'name' : string,
  'totalSupply' : bigint,
  'symbol' : string,
}
export type Result = { 'ok' : null } |
  { 'err' : string };
export type Time = bigint;
export interface Token {
  'allowance' : (arg_0: Principal, arg_1: Principal) => Promise<bigint>,
  'approve' : (arg_0: Principal, arg_1: bigint) => Promise<TxReceipt>,
  'balanceOf' : (arg_0: Principal) => Promise<bigint>,
  'burn' : (arg_0: bigint) => Promise<TxReceipt>,
  'decimals' : () => Promise<number>,
  'distributeRewards' : () => Promise<Result>,
  'distributeStakeDividends' : () => Promise<Result>,
  'endStake' : () => Promise<Result>,
  'getAllowanceSize' : () => Promise<bigint>,
  'getHolders' : (arg_0: bigint, arg_1: bigint) => Promise<
      Array<[Principal, bigint]>
    >,
  'getMetadata' : () => Promise<Metadata>,
  'getTokenFee' : () => Promise<bigint>,
  'getTokenInfo' : () => Promise<TokenInfo>,
  'getUserApprovals' : (arg_0: Principal) => Promise<
      Array<[Principal, bigint]>
    >,
  'historySize' : () => Promise<bigint>,
  'logo' : () => Promise<string>,
  'mint' : (arg_0: Principal, arg_1: bigint) => Promise<TxReceipt>,
  'name' : () => Promise<string>,
  'placeBet' : (arg_0: bigint) => Promise<Result>,
  'setFee' : (arg_0: bigint) => Promise<undefined>,
  'setFeeTo' : (arg_0: Principal) => Promise<undefined>,
  'setLogo' : (arg_0: string) => Promise<undefined>,
  'setName' : (arg_0: string) => Promise<undefined>,
  'setOwner' : (arg_0: Principal) => Promise<undefined>,
  'showStaked' : () => Promise<bigint>,
  'show_time' : () => Promise<bigint>,
  'specialTransfer' : (
      arg_0: Principal,
      arg_1: bigint,
      arg_2: string,
      arg_3: bigint,
    ) => Promise<TxReceipt>,
  'stake' : (arg_0: bigint) => Promise<Result>,
  'symbol' : () => Promise<string>,
  'totalSupply' : () => Promise<bigint>,
  'transfer' : (arg_0: Principal, arg_1: bigint) => Promise<TxReceipt>,
  'transferFrom' : (
      arg_0: Principal,
      arg_1: Principal,
      arg_2: bigint,
    ) => Promise<TxReceipt>,
  'voteDao' : (arg_0: bigint, arg_1: string, arg_2: string) => Promise<
      TxReceipt
    >,
}
export interface TokenInfo {
  'holderNumber' : bigint,
  'deployTime' : Time,
  'metadata' : Metadata,
  'historySize' : bigint,
  'cycles' : bigint,
  'feeTo' : Principal,
}
export type TxReceipt = { 'Ok' : bigint } |
  {
    'Err' : { 'InsufficientAllowance' : null } |
      { 'InsufficientBalance' : null } |
      { 'ErrorOperationStyle' : null } |
      { 'Unauthorized' : null } |
      { 'LedgerTrap' : null } |
      { 'WrongCode' : null } |
      { 'ErrorTo' : null } |
      { 'NotEnoughUnlockedTokens' : null } |
      { 'Other' : string } |
      { 'BlockUsed' : null } |
      { 'AmountTooSmall' : null }
  };
export interface _SERVICE extends Token {}

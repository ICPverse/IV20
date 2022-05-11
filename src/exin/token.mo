import HashMap "mo:base/HashMap";
import Principal "mo:base/Principal";
import Types "dip20_types";
import Time "mo:base/Time";
import Iter "mo:base/Iter";
import Array "mo:base/Array";
import Option "mo:base/Option";
import Order "mo:base/Order";
import Nat "mo:base/Nat";
import Nat64 "mo:base/Nat64";
import Result "mo:base/Result";
import Text "mo:base/Text";
import ExperimentalCycles "mo:base/ExperimentalCycles";
import Cap "../cap/Cap";
import Root "../cap/Root";
import Debug "mo:base/Debug";

shared(msg) actor class Token(
    _logo: Text,
    _name: Text,
    _symbol: Text,
    _decimals: Nat8,
    _totalSupply: Nat,
    _owner: Principal,
    _fee: Nat
    ) = this {
    type Operation = Types.Operation;
    type TransactionStatus = Types.TransactionStatus;
    type TxRecord = Types.TxRecord;
    type Metadata = {
        logo : Text;
        name : Text;
        symbol : Text;
        decimals : Nat8;
        totalSupply : Nat;
        owner : Principal;
        fee : Nat;
    };
    public type Result = Result.Result<(),Text>;
    // returns tx index or error msg
    public type TxReceipt = {
        #Ok: Nat;
        #Err: {
            #InsufficientAllowance;
            #InsufficientBalance;
            #ErrorOperationStyle;
            #Unauthorized;
            #LedgerTrap;
            #ErrorTo;
            #Other: Text;
            #BlockUsed;
            #AmountTooSmall;
            #WrongCode;
            #NotEnoughUnlockedTokens;
            #IncompatibleSpecialTransferCombination;
        };
    };
    private stable var tgeTime : Int = Time.now();
    private stable var owner_ : Principal = _owner;
    private stable var logo_ : Text = _logo;
    private stable var name_ : Text = _name;
    private stable var decimals_ : Nat8 = _decimals;
    private stable var symbol_ : Text = _symbol;
    private stable var totalSupply_ : Nat = _totalSupply;
    private stable var blackhole : Principal = Principal.fromText("aaaaa-aa");
    private stable var feeTo : Principal = owner_;
    private stable var fee : Nat = _fee;
    private stable var balanceEntries : [(Principal, Nat)] = [];
    private stable var allowanceEntries : [(Principal, [(Principal, Nat)])] = [];
    private stable var designationTime : [(Principal,Int)] = [];
    private stable var designationType : [(Principal,Text)] = [];
    private stable var designationAmount : [(Principal,Nat)] = [];
    private stable var stakeTime : [(Principal,Int)] = [];
    private var desTimeHash = HashMap.HashMap<Principal, Int>(0, Principal.equal, Principal.hash);
    private var desTypeHash = HashMap.HashMap<Principal, Text>(0, Principal.equal, Principal.hash);
    private var desAmountHash = HashMap.HashMap<Principal, Nat>(0, Principal.equal, Principal.hash);
    private var stakeTimeHash = HashMap.HashMap<Principal, Int>(0, Principal.equal, Principal.hash);
    private var balances = HashMap.HashMap<Principal, Nat>(1, Principal.equal, Principal.hash);
    private var allowances = HashMap.HashMap<Principal, HashMap.HashMap<Principal, Nat>>(1, Principal.equal, Principal.hash);
    balances.put(owner_, totalSupply_);
    private stable let genesis : TxRecord = {
        caller = ?owner_;
        op = #mint;
        index = 0;
        from = blackhole;
        to = owner_;
        amount = totalSupply_;
        fee = 0;
        timestamp = Time.now();
        status = #succeeded;
    };
    
    private stable var txcounter: Nat = 0;
    private var cap: ?Cap.Cap = null;
    private func addRecord(
        caller: Principal,
        op: Text, 
        details: [(Text, Root.DetailValue)]
        ): async () {
        let c = switch(cap) {
            case(?c) { c };
            case(_) { Cap.Cap(Principal.fromActor(this), 2_000_000_000_000) };
        };
        cap := ?c;
        let record: Root.IndefiniteEvent = {
            operation = op;
            details = details;
            caller = caller;
        };
        // don't wait for result, faster
        ignore c.insert(record);
    };

    private func _chargeFee(from: Principal, fee: Nat) {
        if(fee > 0) {
            _transfer(from, feeTo, fee);
        };
    };

    private func _transfer(from: Principal, to: Principal, value: Nat) {
        let from_balance = _balanceOf(from);
        let from_balance_new : Nat = from_balance - value;
        if (from_balance_new != 0) { balances.put(from, from_balance_new); }
        else { balances.delete(from); };

        let to_balance = _balanceOf(to);
        let to_balance_new : Nat = to_balance + value;
        if (to_balance_new != 0) { balances.put(to, to_balance_new); };
    };

    private func _balanceOf(who: Principal) : Nat {
        switch (balances.get(who)) {
            case (?balance) { return balance; };
            case (_) { return 0; };
        }
    };

    private func _allowance(owner: Principal, spender: Principal) : Nat {
        switch(allowances.get(owner)) {
            case (?allowance_owner) {
                switch(allowance_owner.get(spender)) {
                    case (?allowance) { return allowance; };
                    case (_) { return 0; };
                }
            };
            case (_) { return 0; };
        }
    };

    private func u64(i: Nat): Nat64 {
        Nat64.fromNat(i)
    };

    /*
    This function checks for the minimum balance a wallet is expected to have (that cannot be sold or transferred).
    This check is needed in case a certain number of tokens are "staked", or the wallet belongs to a special role
    such as a Founder, Seed investor, Advisor, etc. 
    The entire vesting schedule for such wallets in enshrined in this function.
    */
    func minBalance(p : Principal) : Nat {
        var minBal = 0;
        var allotTime : Int = 0;
        var numToken = 0;
        let timeOfAllotment = desTimeHash.get(p);
        let typeOfWallet = desTypeHash.get(p);
        let numberOfTokens = desAmountHash.get(p);

            switch (typeOfWallet){
                case null {
                    minBal := 0;
                };
                case (?"Staked") {
                    let stakeDur = stakeTimeHash.get(p);
                    var finalTime : Int = 0;
                    switch (stakeDur) {
                        case null {
                            return 0;
                        };
                        case (?int) {
                            finalTime := int;
                        };
                    };
                    switch (timeOfAllotment) {
                        case null {
                            allotTime := 0;
                        };
                        case (?int) {
                            allotTime := int;
                        };
                    };

                    if (finalTime < Time.now()){
                        minBal := 0;
                        stakeTimeHash.delete(p);
                        desTimeHash.delete(p);
                        desAmountHash.delete(p);
                        desTypeHash.delete(p);
                        return 0;
                    };
                   
                    switch (numberOfTokens) {
                        case null {
                            numToken := 0;
                        };
                        case (?nat) {
                            numToken := nat;
                        };
                    };
                    if (allotTime == 0 or numToken == 0){
                        return 0;
                    }
                    else {
                        return numToken;
                    };

                };
                case (?"Marketing") {
                    switch (timeOfAllotment) {
                        case null {
                            allotTime := 0;
                        };
                        case (?int) {
                            allotTime := int;
                        };
                    };
                   
                    switch (numberOfTokens) {
                        case null {
                            numToken := 0;
                        };
                        case (?nat) {
                            numToken := nat;
                        };
                    };
                    Debug.print(debug_show numToken);
                    if (numToken == 0 or allotTime == 0) {
                        return 0;
                    };
                    let timeElapsedInDays : Int = (Time.now() - allotTime)/(60*60*24*1000000000);
                    Debug.print(debug_show timeElapsedInDays);

                    if (timeElapsedInDays <= 30){
                        minBal := (numToken * 7)/10;
                        return minBal;
                    };
                    if (timeElapsedInDays > 30 and timeElapsedInDays <= 60) {
                        minBal := (numToken * 6)/10;
                        return minBal;
                    };
                    if (timeElapsedInDays > 60 and timeElapsedInDays <= 90) {
                        minBal := (numToken * 5)/10;
                        return minBal;
                    };
                    if (timeElapsedInDays > 90 and timeElapsedInDays <= 120) {
                        minBal := (numToken * 4)/10;
                        return minBal;
                    };
                    if (timeElapsedInDays > 120 and timeElapsedInDays <= 150) {
                        minBal := (numToken * 3)/10;
                        return minBal;
                    };
                    if (timeElapsedInDays > 150 and timeElapsedInDays <= 180) {
                        minBal := (numToken * 2)/10;
                        return minBal;
                    };
                    if (timeElapsedInDays > 180 and timeElapsedInDays <= 210) {
                        minBal := (numToken * 1)/10;
                        return minBal;
                    }
                    else {
                        minBal := 0;
                    };
                };
                case (?"Public") {
                    switch (timeOfAllotment) {
                        case null {
                            allotTime := 0;
                        };
                        case (?int) {
                            allotTime := int;
                        };
                    };
                   
                    switch (numberOfTokens) {
                        case null {
                            numToken := 0;
                        };
                        case (?nat) {
                            numToken := nat;
                        };
                    };
                    Debug.print(debug_show numToken);
                    if (numToken == 0 or allotTime == 0) {
                        return 0;
                    };
                    let timeElapsedInDays : Int = (Time.now() - allotTime)/(60*60*24*1000000000);
                    Debug.print(debug_show timeElapsedInDays);

                    if (timeElapsedInDays <= 30){
                        minBal := numToken;
                        return minBal;
                    };
                    if (timeElapsedInDays > 30 and timeElapsedInDays < 120) {
                        minBal := (numToken * 2)/3;
                        return minBal;
                    };
                    if (timeElapsedInDays > 120 and timeElapsedInDays <= 180) {
                        minBal := (numToken)/3;
                        return minBal;
                    }
                    else {
                        minBal := 0;
                    };

                    minBal := 0;
                };
                case (?"Founder") {
                    switch (timeOfAllotment) {
                        case null {
                            allotTime := 0;
                        };
                        case (?int) {
                            allotTime := int;
                        };
                    };
                   
                    switch (numberOfTokens) {
                        case null {
                            numToken := 0;
                        };
                        case (?nat) {
                            numToken := nat;
                        };
                    };
                    Debug.print(debug_show numToken);
                    if (numToken == 0 or allotTime == 0) {
                        return 0;
                    };
                    let timeElapsedInDays : Int = (Time.now() - allotTime)/(60*60*24*1000000000);
                    Debug.print(debug_show timeElapsedInDays);

                    if (timeElapsedInDays <= 365){
                        minBal := numToken;
                        return minBal;
                    };
                    if (timeElapsedInDays > 365 and timeElapsedInDays <= 455) {
                        minBal := (numToken * 3)/4;
                        return minBal;
                    };
                    if (timeElapsedInDays > 455 and timeElapsedInDays <= 535) {
                        minBal := (numToken)/2;
                        return minBal;
                    };
                    if (timeElapsedInDays > 535 and timeElapsedInDays <= 600) {
                        minBal := (numToken)/4;
                        return minBal;
                    }
                    else {
                        minBal := 0;
                    };

                    
                };
                case (?"Advisor") {
                    switch (timeOfAllotment) {
                        case null {
                            allotTime := 0;
                        };
                        case (?int) {
                            allotTime := int;
                        };
                    };
                   
                    switch (numberOfTokens) {
                        case null {
                            numToken := 0;
                        };
                        case (?nat) {
                            numToken := nat;
                        };
                    };
                    Debug.print(debug_show numToken);
                    if (numToken == 0 or allotTime == 0) {
                        return 0;
                    };
                    let timeElapsedInDays : Int = (Time.now() - allotTime)/(60*60*24*1000000000);
                    Debug.print(debug_show timeElapsedInDays);

                    if (timeElapsedInDays <= 30){
                        minBal := numToken;
                        return minBal;
                    };
                    if (timeElapsedInDays > 30 and timeElapsedInDays <= 120) {
                        minBal := (numToken * 2)/3;
                        return minBal;
                    };
                    if (timeElapsedInDays > 120 and timeElapsedInDays <= 180) {
                        minBal := (numToken)/2;
                        return minBal;
                    };
                    if (timeElapsedInDays > 180 and timeElapsedInDays <= 240) {
                        minBal := (numToken)/4;
                        return minBal;
                    }
                    else {
                        minBal := 0;
                    };
                };
                case (?"Private") {
                    switch (timeOfAllotment) {
                        case null {
                            allotTime := 0;
                        };
                        case (?int) {
                            allotTime := int;
                        };
                    };
                   
                    switch (numberOfTokens) {
                        case null {
                            numToken := 0;
                        };
                        case (?nat) {
                            numToken := nat;
                        };
                    };
                    Debug.print(debug_show numToken);
                    if (numToken == 0 or allotTime == 0) {
                        return 0;
                    };
                    let timeElapsedInDays : Int = (Time.now() - allotTime)/(60*60*24*1000000000);
                    Debug.print(debug_show timeElapsedInDays);

                    if (timeElapsedInDays <= 30){
                        minBal := (numToken*3)/4;
                        return minBal;
                    };
                    if (timeElapsedInDays > 30 and timeElapsedInDays <= 60) {
                        minBal := (numToken)/2;
                        return minBal;
                    };
                    if (timeElapsedInDays > 60 and timeElapsedInDays <= 90) {
                        minBal := (numToken)/4;
                        return minBal;
                    }
                    else {
                        minBal := 0;
                    };
                };
                case (?"Preseed") {
                    switch (timeOfAllotment) {
                        case null {
                            allotTime := 0;
                        };
                        case (?int) {
                            allotTime := int;
                        };
                    };
                   
                    switch (numberOfTokens) {
                        case null {
                            numToken := 0;
                        };
                        case (?nat) {
                            numToken := nat;
                        };
                    };
                    Debug.print(debug_show numToken);
                    if (numToken == 0 or allotTime == 0) {
                        return 0;
                    };
                    let timeElapsedInDays : Int = (Time.now() - allotTime)/(60*60*24*1000000000);
                    Debug.print(debug_show timeElapsedInDays);

                    if (timeElapsedInDays <= 30){
                        minBal := (numToken*7)/10;
                        return minBal;
                    };
                    if (timeElapsedInDays > 30 and timeElapsedInDays <= 60) {
                        minBal := (numToken * 6)/10;
                        return minBal;
                    };
                     if (timeElapsedInDays > 60 and timeElapsedInDays <= 90) {
                        minBal := (numToken * 5)/10;
                        return minBal;
                    };
                     if (timeElapsedInDays > 90 and timeElapsedInDays <= 120) {
                        minBal := (numToken * 4)/10;
                        return minBal;
                    };
                     if (timeElapsedInDays > 120 and timeElapsedInDays <= 150) {
                        minBal := (numToken * 3)/10;
                        return minBal;
                    };
                     if (timeElapsedInDays > 150 and timeElapsedInDays <= 180) {
                        minBal := (numToken * 2)/10;
                        return minBal;
                    };
                    if (timeElapsedInDays > 180 and timeElapsedInDays <= 210) {
                        minBal := (numToken)/10;
                        return minBal;
                    }
                    else {
                        minBal := 0;
                    };
                };
                case (?"Seed") {
                    switch (timeOfAllotment) {
                        case null {
                            allotTime := 0;
                        };
                        case (?int) {
                            allotTime := int;
                        };
                    };
                   
                    switch (numberOfTokens) {
                        case null {
                            numToken := 0;
                        };
                        case (?nat) {
                            numToken := nat;
                        };
                    };
                    Debug.print(debug_show numToken);
                    if (numToken == 0 or allotTime == 0) {
                        return 0;
                    };
                    let timeElapsedInDays : Int = (Time.now() - allotTime)/(60*60*24*1000000000);
                    Debug.print(debug_show timeElapsedInDays);

                    if (timeElapsedInDays <= 30){
                        minBal := (numToken*7)/10;
                        return minBal;
                    };
                    if (timeElapsedInDays > 30 and timeElapsedInDays <= 60) {
                        minBal := (numToken * 6)/10;
                        return minBal;
                    };
                     if (timeElapsedInDays > 60 and timeElapsedInDays <= 90) {
                        minBal := (numToken * 5)/10;
                        return minBal;
                    };
                     if (timeElapsedInDays > 90 and timeElapsedInDays <= 120) {
                        minBal := (numToken * 4)/10;
                        return minBal;
                    };
                     if (timeElapsedInDays > 120 and timeElapsedInDays <= 150) {
                        minBal := (numToken * 3)/10;
                        return minBal;
                    };
                     if (timeElapsedInDays > 150 and timeElapsedInDays <= 180) {
                        minBal := (numToken * 2)/10;
                        return minBal;
                    };
                    if (timeElapsedInDays > 180 and timeElapsedInDays <= 210) {
                        minBal := (numToken)/10;
                        return minBal;
                    }
                    else {
                        minBal := 0;
                    };
                };
                case (?"SeedPreseed") {
                    switch (timeOfAllotment) {
                        case null {
                            allotTime := 0;
                        };
                        case (?int) {
                            allotTime := int;
                        };
                    };
                   
                    switch (numberOfTokens) {
                        case null {
                            numToken := 0;
                        };
                        case (?nat) {
                            numToken := nat;
                        };
                    };
                    Debug.print(debug_show numToken);
                    if (numToken == 0 or allotTime == 0) {
                        return 0;
                    };
                    let timeElapsedInDays : Int = (Time.now() - allotTime)/(60*60*24*1000000000);
                    Debug.print(debug_show timeElapsedInDays);

                    if (timeElapsedInDays <= 30){
                        minBal := (numToken*7)/10;
                        return minBal;
                    };
                    if (timeElapsedInDays > 30 and timeElapsedInDays <= 60) {
                        minBal := (numToken * 6)/10;
                        return minBal;
                    };
                     if (timeElapsedInDays > 60 and timeElapsedInDays <= 90) {
                        minBal := (numToken * 5)/10;
                        return minBal;
                    };
                     if (timeElapsedInDays > 90 and timeElapsedInDays <= 120) {
                        minBal := (numToken * 4)/10;
                        return minBal;
                    };
                     if (timeElapsedInDays > 120 and timeElapsedInDays <= 150) {
                        minBal := (numToken * 3)/10;
                        return minBal;
                    };
                     if (timeElapsedInDays > 150 and timeElapsedInDays <= 180) {
                        minBal := (numToken * 2)/10;
                        return minBal;
                    };
                    if (timeElapsedInDays > 180 and timeElapsedInDays <= 210) {
                        minBal := (numToken)/10;
                        return minBal;
                    }
                    else {
                        minBal := 0;
                    };
                };
                case (?"PreseedAdvisor") {
                    switch (timeOfAllotment) {
                        case null {
                            allotTime := 0;
                        };
                        case (?int) {
                            allotTime := int;
                        };
                    };
                   
                    switch (numberOfTokens) {
                        case null {
                            numToken := 0;
                        };
                        case (?nat) {
                            numToken := nat;
                        };
                    };
                    Debug.print(debug_show numToken);
                    if (numToken == 0 or allotTime == 0) {
                        return 0;
                    };
                    let timeElapsedInDays : Int = (Time.now() - allotTime)/(60*60*24*1000000000);
                    Debug.print(debug_show timeElapsedInDays);

                    if (timeElapsedInDays <= 30){
                        minBal := (numToken*7)/10;
                        return minBal;
                    };
                    if (timeElapsedInDays > 30 and timeElapsedInDays <= 60) {
                        minBal := (numToken * 6)/10;
                        return minBal;
                    };
                     if (timeElapsedInDays > 60 and timeElapsedInDays <= 90) {
                        minBal := (numToken * 5)/10;
                        return minBal;
                    };
                     if (timeElapsedInDays > 90 and timeElapsedInDays <= 120) {
                        minBal := (numToken * 4)/10;
                        return minBal;
                    };
                     if (timeElapsedInDays > 120 and timeElapsedInDays <= 150) {
                        minBal := (numToken * 3)/10;
                        return minBal;
                    };
                     if (timeElapsedInDays > 150 and timeElapsedInDays <= 180) {
                        minBal := (numToken * 2)/10;
                        return minBal;
                    };
                    if (timeElapsedInDays > 180 and timeElapsedInDays <= 210) {
                        minBal := (numToken)/10;
                        return minBal;
                    }
                    else {
                        minBal := 0;
                    };
                };
                case (?"SeedAdvisor") {
                    switch (timeOfAllotment) {
                        case null {
                            allotTime := 0;
                        };
                        case (?int) {
                            allotTime := int;
                        };
                    };
                   
                    switch (numberOfTokens) {
                        case null {
                            numToken := 0;
                        };
                        case (?nat) {
                            numToken := nat;
                        };
                    };
                    Debug.print(debug_show numToken);
                    if (numToken == 0 or allotTime == 0) {
                        return 0;
                    };
                    let timeElapsedInDays : Int = (Time.now() - allotTime)/(60*60*24*1000000000);
                    Debug.print(debug_show timeElapsedInDays);

                    if (timeElapsedInDays <= 30){
                        minBal := (numToken*7)/10;
                        return minBal;
                    };
                    if (timeElapsedInDays > 30 and timeElapsedInDays <= 60) {
                        minBal := (numToken * 6)/10;
                        return minBal;
                    };
                     if (timeElapsedInDays > 60 and timeElapsedInDays <= 90) {
                        minBal := (numToken * 5)/10;
                        return minBal;
                    };
                     if (timeElapsedInDays > 90 and timeElapsedInDays <= 120) {
                        minBal := (numToken * 4)/10;
                        return minBal;
                    };
                     if (timeElapsedInDays > 120 and timeElapsedInDays <= 150) {
                        minBal := (numToken * 3)/10;
                        return minBal;
                    };
                     if (timeElapsedInDays > 150 and timeElapsedInDays <= 180) {
                        minBal := (numToken * 2)/10;
                        return minBal;
                    };
                    if (timeElapsedInDays > 180 and timeElapsedInDays <= 210) {
                        minBal := (numToken)/10;
                        return minBal;
                    }
                    else {
                        minBal := 0;
                    };
                };
                case (?"Treasury") {
                    switch (timeOfAllotment) {
                        case null {
                            allotTime := 0;
                        };
                        case (?int) {
                            allotTime := int;
                        };
                    };
                   
                    switch (numberOfTokens) {
                        case null {
                            numToken := 0;
                        };
                        case (?nat) {
                            numToken := nat;
                        };
                    };
                    Debug.print(debug_show numToken);
                    if (numToken == 0 or allotTime == 0) {
                        return 0;
                    };
                    let timeElapsedInDays : Int = (Time.now() - allotTime)/(60*60*24*1000000000);
                    Debug.print(debug_show timeElapsedInDays);

                    if (timeElapsedInDays <= 30){
                        minBal := (numToken * 3)/4;
                        return minBal;
                    };
                    if (timeElapsedInDays > 30 and timeElapsedInDays <= 60) {
                        minBal := (numToken * 67)/100;
                        return minBal;
                    };
                    if (timeElapsedInDays > 60 and timeElapsedInDays <= 90) {
                        minBal := (numToken * 59)/100;
                        return minBal;
                    };
                    if (timeElapsedInDays > 90 and timeElapsedInDays <= 120) {
                        minBal := (numToken * 51)/100;
                        return minBal;
                    };
                    if (timeElapsedInDays > 120 and timeElapsedInDays <= 150) {
                        minBal := (numToken * 43)/100;
                        return minBal;
                    };
                    if (timeElapsedInDays > 150 and timeElapsedInDays <= 180) {
                        minBal := (numToken * 35)/100;
                        return minBal;
                    };
                    
                    if (timeElapsedInDays > 180 and timeElapsedInDays <= 210) {
                        minBal := (numToken * 30)/100;
                        return minBal;
                    };
                    if (timeElapsedInDays > 210 and timeElapsedInDays <= 240) {
                        minBal := (numToken * 25)/100;
                        return minBal;
                    };
                    if (timeElapsedInDays > 240 and timeElapsedInDays <= 270) {
                        minBal := (numToken * 20)/100;
                        return minBal;
                    };
                    if (timeElapsedInDays > 270 and timeElapsedInDays <= 300) {
                        minBal := (numToken * 15)/100;
                        return minBal;
                    };
                    if (timeElapsedInDays > 300 and timeElapsedInDays <= 330) {
                        minBal := (numToken * 10)/100;
                        return minBal;
                    };
                    if (timeElapsedInDays > 330 and timeElapsedInDays <= 360) {
                        minBal := (numToken * 5)/100;
                        return minBal;
                    }
                    else {
                        minBal := 0;
                    };
                };
                case default {
                    minBal := 0;
                };
            };
        return minBal;
    };

    /*
    *   Core interfaces:
    *       update calls:
    *           transfer/transferFrom/approve
    *       query calls:
    *           logo/name/symbol/decimal/totalSupply/balanceOf/allowance/getMetadata
    *           historySize/getTransaction/getTransactions
    */

    /// Transfers value amount of tokens to Principal to.
    public shared(msg) func transfer(to: Principal, value: Nat) : async TxReceipt {
        if (_balanceOf(msg.caller) < value + fee) { return #Err(#InsufficientBalance); };
        if (_balanceOf(msg.caller) < value + fee + minBalance(msg.caller)) { return #Err(#NotEnoughUnlockedTokens); };
        _chargeFee(msg.caller, fee);
        _transfer(msg.caller, to, value);
        ignore addRecord(
            msg.caller, "transfer",
            [
                ("to", #Principal(to)),
                ("value", #U64(u64(value))),
                ("fee", #U64(u64(fee)))
            ]
        );
        txcounter += 1;
        return #Ok(txcounter - 1);
    };

   /* Transfers value amount of tokens to Principal to while assigning that principal the role code.
      code can have 8 values: Founder, Advisor, Preseed, Seed, Private, Public, Treasury, Marketing.
      axis represents the point in time from which the vesting is being measured: 0 for vesting
      from Token Generation Event, 1 for vesting starting with this particular transfer.
      The function also ensures that non compatible combinations like Preseed Public, or Advisor Treasury are 
      not assigned. The compatible combinations like SeedAdvisor and SeedPreseed are auto created as well.
    */
    public shared(msg) func specialTransfer(to: Principal, value: Nat, code: Text, axis: Nat) : async TxReceipt {
        if (msg.caller != owner_){
            return #Err(#Unauthorized);
        };
        if (axis != 0 and axis != 1){
            return #Err(#WrongCode);
        };
        if (Text.notEqual(code, "Founder") and Text.notEqual(code, "Preseed") and Text.notEqual(code, "Seed") and Text.notEqual(code, "Advisor") and Text.notEqual(code, "Public") and Text.notEqual(code, "Private") and Text.notEqual(code, "Marketing") and Text.notEqual(code, "Treasury")){
            return #Err(#WrongCode);
        };
        if (_balanceOf(msg.caller) < value + fee) { return #Err(#InsufficientBalance); };
        let currentCodeOpt = desTypeHash.get(to);
        var currentCode = "";
        switch(currentCodeOpt){
            case null{
                currentCode := code;
            };
            case (?"Advisor") {
                switch code {
                    case "Preseed"{
                        currentCode := "PreseedAdvisor";
                    };
                    case "Seed"{
                        currentCode := "SeedAdvisor";
                    };
                    case _{
                        currentCode := "Incompatible";
                    };
                };
            };
            case (?"Preseed") {
                if (code == "Seed"){
                    currentCode := "SeedPreseed";
                }
                else {
                    currentCode := "Incompatible";
                };
            };
            case (?text){
                currentCode := "Incompatible";
            };
        };
        if (currentCode == "Incompatible"){
            return #Err(#IncompatibleSpecialTransferCombination)
        };
        _chargeFee(msg.caller, fee);
        _transfer(msg.caller, to, value);
        ignore addRecord(
            msg.caller, "transfer",
            [
                ("to", #Principal(to)),
                ("value", #U64(u64(value))),
                ("fee", #U64(u64(fee)))
            ]
        );
        txcounter += 1;
        var timeAxis : Int = 0;
        Debug.print(debug_show tgeTime);
        if (axis == 0){
            timeAxis := tgeTime;
        }
        else {
            timeAxis := Time.now();
        };
        var currentAmount = 0;
        if (currentCode != code){
            let res = desTypeHash.replace(to, currentCode);
            let currentAmountOpt = desAmountHash.get(to);
            
            switch (currentAmountOpt){
                case null{
                    currentAmount := 0;
                };
                case (?nat){
                    currentAmount := nat;
                };
            };
            let res2 = desAmountHash.replace(to,currentAmount+value);
        }
        else {
            desAmountHash.put(to,value);
            desTimeHash.put(to,timeAxis);
            desTypeHash.put(to,currentCode);
        };
        return #Ok(txcounter - 1);
    };

    /// Transfers value amount of tokens from Principal from to Principal to.
    public shared(msg) func transferFrom(from: Principal, to: Principal, value: Nat) : async TxReceipt {
        if (_balanceOf(from) < value + fee) { return #Err(#InsufficientBalance); };
        if (_balanceOf(from) < value + fee + minBalance(from)) { return #Err(#NotEnoughUnlockedTokens); };
        let allowed : Nat = _allowance(from, msg.caller);
        if (allowed < value + fee) { return #Err(#InsufficientAllowance); };
        _chargeFee(from, fee);
        _transfer(from, to, value);
        let allowed_new : Nat = allowed - value - fee;
        if (allowed_new != 0) {
            let allowance_from = Types.unwrap(allowances.get(from));
            allowance_from.put(msg.caller, allowed_new);
            allowances.put(from, allowance_from);
        } else {
            if (allowed != 0) {
                let allowance_from = Types.unwrap(allowances.get(from));
                allowance_from.delete(msg.caller);
                if (allowance_from.size() == 0) { allowances.delete(from); }
                else { allowances.put(from, allowance_from); };
            };
        };
        ignore addRecord(
            msg.caller, "transferFrom",
            [
                ("from", #Principal(from)),
                ("to", #Principal(to)),
                ("value", #U64(u64(value))),
                ("fee", #U64(u64(fee)))
            ]
        );
        txcounter += 1;
        return #Ok(txcounter - 1);
    };

    /// Allows spender to withdraw from your account multiple times, up to the value amount.
    /// If this function is called again it overwrites the current allowance with value.
    public shared(msg) func approve(spender: Principal, value: Nat) : async TxReceipt {
        if(_balanceOf(msg.caller) < fee) { return #Err(#InsufficientBalance); };
        _chargeFee(msg.caller, fee);
        let v = value + fee;
        if (value == 0 and Option.isSome(allowances.get(msg.caller))) {
            let allowance_caller = Types.unwrap(allowances.get(msg.caller));
            allowance_caller.delete(spender);
            if (allowance_caller.size() == 0) { allowances.delete(msg.caller); }
            else { allowances.put(msg.caller, allowance_caller); };
        } else if (value != 0 and Option.isNull(allowances.get(msg.caller))) {
            var temp = HashMap.HashMap<Principal, Nat>(1, Principal.equal, Principal.hash);
            temp.put(spender, v);
            allowances.put(msg.caller, temp);
        } else if (value != 0 and Option.isSome(allowances.get(msg.caller))) {
            let allowance_caller = Types.unwrap(allowances.get(msg.caller));
            allowance_caller.put(spender, v);
            allowances.put(msg.caller, allowance_caller);
        };
        ignore addRecord(
            msg.caller, "approve",
            [
                ("to", #Principal(spender)),
                ("value", #U64(u64(value))),
                ("fee", #U64(u64(fee)))
            ]
        );
        txcounter += 1;
        return #Ok(txcounter - 1);
    };

    public shared(msg) func mint(to: Principal, value: Nat): async TxReceipt {
        
        if(msg.caller != owner_) {
            return #Err(#Unauthorized);
        };
      
        let to_balance = _balanceOf(to);
        totalSupply_ += value;
        balances.put(to, to_balance + value);
        ignore addRecord(
            msg.caller, "mint",
            [
                ("to", #Principal(to)),
                ("value", #U64(u64(value))),
                ("fee", #U64(u64(0)))
            ]
        );
        txcounter += 1;
        return #Ok(txcounter - 1);
    };

    public shared(msg) func burn(amount: Nat): async TxReceipt {
        let from_balance = _balanceOf(msg.caller);
        if(from_balance < amount) {
            return #Err(#InsufficientBalance);
        };
        totalSupply_ -= amount;
        balances.put(msg.caller, from_balance - amount);
        ignore addRecord(
            msg.caller, "burn",
            [
                ("from", #Principal(msg.caller)),
                ("value", #U64(u64(amount))),
                ("fee", #U64(u64(0)))
            ]
        );
        txcounter += 1;
        return #Ok(txcounter - 1);
    };

    /*
      This function is called for voting purposes. The maximum votes per wallet are capped such that
      the net burn does not exceed 10000 tokens.
    */
    public shared({caller}) func voteDao(votes: Nat, choice: Text, statement: Text) : async TxReceipt {
        let from_balance = _balanceOf(caller);
	var deduction = 0;
        if (votes * 10 > 10000){
            deduction := 10000;
        }
        else {
            deduction := votes * 10;
        }; 
        if(from_balance < deduction) {
            return #Err(#InsufficientBalance);
        };
        totalSupply_ -= deduction;
        balances.put(caller, from_balance - deduction);
        ignore addRecord(
            caller, "burn",
            [
                ("from", #Principal(caller)),
                ("value", #U64(u64(deduction))),
                ("fee", #U64(u64(0)))
            ]
        );
        txcounter += 1;
        return #Ok(txcounter - 1);
    };

    /*
        A "stakelike" functionality is created whereby the user can lock an amount of tokens and receive 
        monthly dividends. It is different from "true" staking in that ICPV does not have its own block
        chain, and hence no nodes. But from the user perspective, the behavior mimics staking.
    */
    public shared({caller}) func stake(amount: Nat): async Result {
        let typeOfWallet = desTypeHash.get(caller);
        
        switch (typeOfWallet) {
            case null {
                if(_balanceOf(caller) < amount) {
                    return #err("Not enough balance.");
                }
                else {
                    let timeInInt : Int = 30*(3600 * 24 * 1000000000) + Time.now();
                    desAmountHash.put(caller,amount);
                    desTimeHash.put(caller,Time.now());
                    desTypeHash.put(caller,"Staked");
                    stakeTimeHash.put(caller,timeInInt);
                    return #ok;
                };
            };
            case (?"Staked") {
                var alreadyStaked = 0;
                let lockedTokens = desAmountHash.get(caller);
                var expiry : Int = 0;
                var start : Int = 0;
                let startTime = desTimeHash.get(caller);
                let expiryTime = stakeTimeHash.get(caller);
                switch (startTime){
                    case null {
                        start := 0; 
                    };
                    case (?int) {
                        start := int;
                    };
                };
                switch (expiryTime) {
                    case null {
                        expiry := 0;
                    };
                    case (?int) {
                        expiry := int;
                    };
                };

                switch (lockedTokens) {
                    case null {
                        alreadyStaked := 0;
                    };
                    case (?nat) {
                        alreadyStaked := nat;
                    };
                };
                if (expiry < Time.now() and expiry != 0){
                    alreadyStaked := 0;
                };
                if (_balanceOf(caller) < amount + alreadyStaked){
                    return #err("Not enough unlocked tokens");
                }
                else {
                    desAmountHash.delete(caller);
                    desTimeHash.delete(caller);
                    stakeTimeHash.delete(caller);
                    let timeInInt : Int = 30*(3600 * 24 * 1000000000) + Time.now();
                    desAmountHash.put(caller,amount + alreadyStaked);
                    desTimeHash.put(caller,Time.now());
                    stakeTimeHash.put(caller,timeInInt);
                    return #ok;
                  
                };
            };
            case default {
                return #err("You are a special Founder/Investor wallet. Please use an alternate wallet.")
            };

            
        }; 

    };

    public shared({caller}) func showStaked() : async Nat {
        let walletType = desTypeHash.get(caller);
        switch (walletType){
            case null {
                return 0;
            };
            case (?"Staked") {
                let tokenAmt = desAmountHash.get(caller);
                var tokens = 0;
                switch (tokenAmt) {
                    case null {
                        return 0;
                    };
                    case (?nat){
                        tokens := nat;
                        return tokens;
                    };
                    
                };
            };
            case default {
                return 0;
            };
        };
    };

    /*
        The default functional behavior is to automatically renew the stakes every month end, but a subsequent 
        function shall exist to terminate the staked position at any point.
    */
    private func autoRenewStake(p: Principal) : (){
        let currentExpiration = stakeTimeHash.get(p);
        var newExpiration  = 0;
        var days: Nat = 30;
        switch (currentExpiration){
            case null {
                newExpiration := days;
            };
            case (?int) {
                newExpiration := days;
            };
        };
        let newExp : Int = (3600*24*1000000000)*days + Time.now();
        let newVal = stakeTimeHash.replace(p,newExp);
        let newDes = desTimeHash.replace(p,Time.now());

    };
    public query func logo() : async Text {
        return logo_;
    };

    public query func name() : async Text {
        return name_;
    };

    public query func symbol() : async Text {
        return symbol_;
    };

    public query func decimals() : async Nat8 {
        return decimals_;
    };

    public query func totalSupply() : async Nat {
        return totalSupply_;
    };

    public query func getTokenFee() : async Nat {
        return fee;
    };

    public query func balanceOf(who: Principal) : async Nat {
        return _balanceOf(who);
    };

    public query func allowance(owner: Principal, spender: Principal) : async Nat {
        return _allowance(owner, spender);
    };

    public query func getMetadata() : async Metadata {
        return {
            logo = logo_;
            name = name_;
            symbol = symbol_;
            decimals = decimals_;
            totalSupply = totalSupply_;
            owner = owner_;
            fee = fee;
        };
    };

    /// Get transaction history size
    public query func historySize() : async Nat {
        return txcounter;
    };

    /*
    *   Optional interfaces:
    *       setName/setLogo/setFee/setFeeTo/setOwner
    *       getUserTransactionsAmount/getUserTransactions
    *       getTokenInfo/getHolders/getUserApprovals
    */
    public shared(msg) func setName(name: Text) {
        assert(msg.caller == owner_);
        name_ := name;
    };

    public shared(msg) func setLogo(logo: Text) {
        assert(msg.caller == owner_);
        logo_ := logo;
    };

    public shared(msg) func setFeeTo(to: Principal) {
        assert(msg.caller == owner_);
        feeTo := to;
    };

    public shared(msg) func setFee(_fee: Nat) {
        assert(msg.caller == owner_);
        fee := _fee;
    };

    public shared(msg) func setOwner(_owner: Principal) {
        assert(msg.caller == owner_);
        owner_ := _owner;
    };

    public type TokenInfo = {
        metadata: Metadata;
        feeTo: Principal;
        // status info
        historySize: Nat;
        deployTime: Time.Time;
        holderNumber: Nat;
        cycles: Nat;
    };
    public query func getTokenInfo(): async TokenInfo {
        {
            metadata = {
                logo = logo_;
                name = name_;
                symbol = symbol_;
                decimals = decimals_;
                totalSupply = totalSupply_;
                owner = owner_;
                fee = fee;
            };
            feeTo = feeTo;
            historySize = txcounter;
            deployTime = genesis.timestamp;
            holderNumber = balances.size();
            cycles = ExperimentalCycles.balance();
        }
    };

    public query func getHolders(start: Nat, limit: Nat) : async [(Principal, Nat)] {
        let temp =  Iter.toArray(balances.entries());
        func order (a: (Principal, Nat), b: (Principal, Nat)) : Order.Order {
            return Nat.compare(b.1, a.1);
        };
        let sorted = Array.sort(temp, order);
        let limit_: Nat = if(start + limit > temp.size()) {
            temp.size() - start
        } else {
            limit
        };
        let res = Array.init<(Principal, Nat)>(limit_, (owner_, 0));
        for (i in Iter.range(0, limit_ - 1)) {
            res[i] := sorted[i+start];
        };
        return Array.freeze(res);
    };

    public query func getAllowanceSize() : async Nat {
        var size : Nat = 0;
        for ((k, v) in allowances.entries()) {
            size += v.size();
        };
        return size;
    };

    public query func getUserApprovals(who : Principal) : async [(Principal, Nat)] {
        switch (allowances.get(who)) {
            case (?allowance_who) {
                return Iter.toArray(allowance_who.entries());
            };
            case (_) {
                return [];
            };
        }
    };

    public shared({caller}) func getMyStats() : async Text {
        let bal = balances.get(caller);
        var balance = 0;
        switch bal{
            case null{
                balance := 0;
            };
            case (?nat){
                balance := nat;
            };
        };
        let typeOfWallet = desTypeHash.get(caller);
        var typeInfo = "";
        switch typeOfWallet{
            case null{
                typeInfo := "Normal";
            };
            case (?text){
                typeInfo := text;
            };
        };
        return "Wallet Address " # Principal.toText(caller) # " of type " # typeInfo # " and balance: " # Nat.toText(balance);
    };


    /*
        Manually end your staked positions such that all tokens (non vested) get immediately unlocked.
        Necessary to counter the auto stake functionality.
    */
    public shared({caller}) func endStake() : async Result {
        let walletType = desTypeHash.get(caller);
        switch (walletType){
            case null {
                return #ok;
            };
            case (?"Staked"){
                desAmountHash.delete(caller);
                desTypeHash.delete(caller);
                desTimeHash.delete(caller);
                stakeTimeHash.delete(caller);
                return #ok;
            };
            case default {
                return #ok;
            };
        };
    };

    /*
        Function to distribute the staking rewards. Will be automatically called from the JS layer
        every month end.
    */
    public shared({caller}) func distributeStakeDividends() : async Result {
        if (caller != owner_){
            return #err("Only the owner can call this method.");
        };
        for (key in stakeTimeHash.keys()){
            //Debug.print(debug_show key);
            let expiryTime = stakeTimeHash.get(key);
            var expiry : Int = 0;
            switch (expiryTime) {
                case null {
                    expiry := 0;
                };
                case (?int) {
                    expiry := int;
                };
            };
            //Debug.print(debug_show (Time.now() - expiry));
            if (Time.now() > expiry) {
                let amountStaked = desAmountHash.get(key);
                var amount = 0;
                switch (amountStaked){
                    case null{
                        amount := 0;
                    };
                    case (?nat){
                        amount := nat;
                    };
                };
                var reward : Nat = amount / 100;
                var stake_fee : Nat = amount / 1000;
                //Debug.print(debug_show reward);
                let txn = await mint(key,reward + stake_fee);
                let to_balance = _balanceOf(key);
                totalSupply_ += (reward + stake_fee);
                balances.put(key, to_balance + reward);
                ignore addRecord(
                    caller, "mint",
                    [
                        ("to", #Principal(key)),
                        ("value", #U64(u64(reward))),
                        ("fee", #U64(u64(0)))
                    ]
                );
                txcounter += 1;
                autoRenewStake(key);
            };
        };
        return #ok;
    };

    /*
        The reward system for the vested wallets (since explicit staking isn't allowed for them to avoid whale
        activity). Gets called automatically every month end from the JS layer.
    */
    public shared({caller}) func distributeVestingDividends() : async Result {
        if (caller != owner_){
            return #err("Only the owner can call this method.");
        };
        for (key in desTypeHash.keys()){
            //Debug.print(debug_show key);
            let vestingType = desTypeHash.get(key);
            var benefitAmount : Nat = 0;
            switch (vestingType) {
                case null {
                    benefitAmount := 0;
                };
                case (?"Stake") {
                    benefitAmount := 0;
                };
                case (?text) {
                    benefitAmount := minBalance(key);
                };
            };
            if (benefitAmount > 0){
                var reward : Nat = benefitAmount / 100;
                var stake_fee : Nat = benefitAmount / 1000;
                //Debug.print(debug_show reward);
                let txn = await mint(key,reward + stake_fee);
                let to_balance = _balanceOf(key);
                totalSupply_ += (reward + stake_fee);
                balances.put(key, to_balance + reward);
                ignore addRecord(
                    caller, "mint",
                    [
                        ("to", #Principal(key)),
                        ("value", #U64(u64(reward))),
                        ("fee", #U64(u64(0)))
                    ]
                );
                txcounter += 1;
                
            };
        };
        return #ok;
    };

    var prizePool = 0;
    var betData = HashMap.HashMap<Principal,Nat>(0,Principal.equal,Principal.hash);
    var performanceData = HashMap.HashMap<Principal,Nat>(0,Principal.equal,Principal.hash);
    private stable var betEntries : [(Principal, Nat)] = [];
    private stable var performanceEntries : [(Principal, Nat)] = [];

   
    /*
        The betting function for anyone playing an externally integrated P2E game on the platform.
        Helps bring even non on chain games IC connectivity as a P2E.
    */
    public shared({caller}) func placeBet(amount : Nat) : async Result {
        if (_balanceOf(caller) < fee + amount){
            return #err("Balance too less.");
        };
        if (_balanceOf(caller) < amount + fee + minBalance(caller)) { 
            return #err("Balance too less after locking.");
        }
        else {
            Debug.print(debug_show _balanceOf(caller));
            //let tfr = _transfer(caller, owner_, amount);
            _chargeFee(caller, fee);
            _transfer(caller, owner_, amount);
            ignore addRecord(
                caller, "transfer",
                [
                    ("to", #Principal(owner_)),
                    ("value", #U64(u64(amount))),
                    ("fee", #U64(u64(fee)))
                ]
            );
            txcounter += 1;
            betData.put(caller,amount);
            prizePool += amount;
            Debug.print(debug_show _balanceOf(caller));

            return #ok;
        };
    }; 

    /* This function is used to receive leaderboard data from the Game or Metaverse project that is externally integrated. 
    One of the ways to do this could be to transmit a txt file at the end of every contest duration to the integrating side, 
    from the integratee side, and then separating each line to respective ranking and Principal IDs. For demo and test
    purposes, we have just provided the barebones structure of the receivePerformanceData method.
    */
    func receivePerformanceData(p : Principal, rank : Nat) : () {
        performanceData.put(p,rank);
    };
    //Below are test values with 4 identities created locally and they are useful only for test purposes with 
    //the corresponding values obtained from your own 4 created identities.
    /*
        receivePerformanceData(Principal.fromText("qtuga-kg7hz-d56lf-kfuak-jy6gl-jzfeg-iavcg-a2d2v-bh2cp-egdc2-kqe"),1);
        receivePerformanceData(Principal.fromText("ye3vr-uyipa-xdzgw-obowr-ouiwt-uiug3-b34te-xsrfs-orwos-nuok4-qqe"),2);
        receivePerformanceData(Principal.fromText("o3kju-fu2qh-kcth4-jxmet-37zti-m3shd-nns7f-keorq-zp3xd-vwd42-kqe"),3);
        receivePerformanceData(Principal.fromText("whp3z-x6a6g-qewwq-ewcce-j72e5-rua3p-x2ake-4ujl5-j545k-sfkvv-zqe"),4);
    */




    /*
        The function to distribute the P2E rewards for the externally integrated games on the platform.
        A small platform fee is kept and the remaining is distributed to the top performers as a weighed
        fraction of both, their ante and their position on the leaderboard.
    */
    public shared({caller}) func distributeRewards() : async Result {
        if (caller != owner_){
            return #err("Only the owner can access this method");
        };
        var distPool = 0;
        var unDistPoolCoeff = 0;
        var award = 0;
        var bet = 0;
        var rank = 0;
        let n = performanceData.size();
        
        for (better in betData.keys()){
            let btr = betData.get(better);
            switch (btr){
                case null {
                    bet := 0;
                };
                case (?nat) {
                    bet := nat;
                };
            };
            let rnk = performanceData.get(better);
            switch (rnk) {
                case null {
                    rank := 0;
                };
                case (?nat){
                    rank := nat;
                };
            };
            if (rank > n/2){
                distPool += bet;
            }
            else {
                unDistPoolCoeff += bet*(n - rank);
            };
        };
        distPool := 85*distPool/100; //Taking out the platform profit

        for (better2 in betData.keys()){
            let btr2 = betData.get(better2);
            switch (btr2){
                case null {
                    bet := 0;
                };
                case (?nat) {
                    bet := nat;
                };
            };
            let rnk2 = performanceData.get(better2);
            switch (rnk2) {
                case null {
                    rank := 0;
                };
                case (?nat){
                    rank := nat;
                };
            };
            if (rank <= n/2 and rank != 0 and bet != 0){
                award := bet + ((bet * (n - rank) * distPool)/unDistPoolCoeff) - 2*fee;
                _chargeFee(caller, fee);
                 _transfer(caller, better2, award);
                ignore addRecord(
                    caller, "transfer",
                    [
                        ("to", #Principal(better2)),
                        ("value", #U64(u64(award))),
                        ("fee", #U64(u64(fee)))
                     ]
                );
                txcounter += 1;
                
                
                };
        };
        resetContest();
        return #ok;
        
    };
    //The above function uses a dual-weighed discrete distributed system to assign weights for each winner
    //based on both: rank and amount they bet.


    /*
        Resets the contest after distributing the rewards for the previous contest period.
        The contest period for all leaderboard games is currently set to 7 days.
    */
    func resetContest() : () {
        betEntries := [];
        performanceEntries := [];
        betData := HashMap.fromIter<Principal, Nat>(betEntries.vals(), 1, Principal.equal, Principal.hash);
        performanceData := HashMap.fromIter<Principal, Nat>(performanceEntries.vals(), 1, Principal.equal, Principal.hash);
        prizePool := 0;
    };

    public func show_time() : async Int {
        let now = Time.now()/1000000000;
        return now;
    };

    /*
    * upgrade functions
    */
    system func preupgrade() {
        balanceEntries := Iter.toArray(balances.entries());
        betEntries := Iter.toArray(betData.entries());
        performanceEntries := Iter.toArray(performanceData.entries());
        var size : Nat = allowances.size();
        var temp : [var (Principal, [(Principal, Nat)])] = Array.init<(Principal, [(Principal, Nat)])>(size, (owner_, []));
        size := 0;
        for ((k, v) in allowances.entries()) {
            temp[size] := (k, Iter.toArray(v.entries()));
            size += 1;
        };
        allowanceEntries := Array.freeze(temp);
        designationAmount := Iter.toArray(desAmountHash.entries());
        designationTime := Iter.toArray(desTimeHash.entries());
        designationType := Iter.toArray(desTypeHash.entries());
        stakeTime := Iter.toArray(stakeTimeHash.entries());
    };

    system func postupgrade() {
        balances := HashMap.fromIter<Principal, Nat>(balanceEntries.vals(), 1, Principal.equal, Principal.hash);
        betData := HashMap.fromIter<Principal, Nat>(betEntries.vals(), 1, Principal.equal, Principal.hash);
        performanceData := HashMap.fromIter<Principal, Nat>(performanceEntries.vals(), 1, Principal.equal, Principal.hash);
        desAmountHash := HashMap.fromIter<Principal, Nat>(designationAmount.vals(), 1, Principal.equal, Principal.hash);
        desTypeHash := HashMap.fromIter<Principal, Text>(designationType.vals(), 1, Principal.equal, Principal.hash);
        desTimeHash := HashMap.fromIter<Principal, Int>(designationTime.vals(), 1, Principal.equal, Principal.hash);
        stakeTimeHash := HashMap.fromIter<Principal, Int>(stakeTime.vals(), 1, Principal.equal, Principal.hash);
        balanceEntries := [];
        betEntries := [];
        performanceEntries := [];
        for ((k, v) in allowanceEntries.vals()) {
            let allowed_temp = HashMap.fromIter<Principal, Nat>(v.vals(), 1, Principal.equal, Principal.hash);
            allowances.put(k, allowed_temp);
        };
        allowanceEntries := [];
        designationAmount := [];
        designationTime := [];
        designationType := [];
        stakeTime := [];
    };
};

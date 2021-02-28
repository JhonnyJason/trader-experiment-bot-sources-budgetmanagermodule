budgetmanagermodule = {name: "budgetmanagermodule"}
############################################################
#region printLogFunctions
log = (arg) ->
    if allModules.debugmodule.modulesToDebug["budgetmanagermodule"]?  then console.log "[budgetmanagermodule]: " + arg
    return
ostr = (obj) -> JSON.stringify(obj, null, 4)
olog = (obj) -> log "\n" + ostr(obj)
print = (arg) -> console.log(arg)
#endregion

############################################################
#region modules
situationAnalyzer = null
state = null
cfg = null

#endregion

############################################################
#region internalProperties
allBudgets = {}
availableBudgets = {}

situations = {}

allLogs = 
    logs: []
    size: 1024
#endregion

############################################################
budgetmanagermodule.initialize = ->
    log "budgetmanagermodule.initialize"
    situationAnalyzer = allModules.situationanalyzermodule
    state = allModules.persistentstatemodule
    cfg = allModules.configmodule
    situations = situationAnalyzer.situations

    allBudgets = state.load("allBudgets")
    loadedLogs = state.load("activityLog")
    if loadedLogs.logs? then allLogs = loadedLogs

    summarizeAvailableBudget()
    return
    
############################################################
#region internalFunctionss
activityLog = (message) ->
    log message
    time = new Date()
    message = ""+time.toISOString()+"| "+message
    allLogs.logs.unshift(message)
    allLogs.logs.length = allLogs.size
    return


############################################################
budgetNumber = (exactNumber) ->
    number = 100000000 * exactNumber
    number = Math.round(number)
    number = 0.00000001 * number
    return number

save = ->
    state.save("allBudgets", allBudgets)
    state.save("activityLog", allLogs)
    summarizeAvailableBudget()
    return

############################################################
#region summarizeAvailableBudget
summarizeAvailableBudget = ->
    for exchange,exchangeSituation of situations
        summarizeExchangeSituation(exchange, exchangeSituation)
    return

############################################################
summarizeExchangeSituation = (exchange, situation) ->
    if !availableBudgets[exchange]? then availableBudgets[exchange] = {}
    return unless situation.latestBalances?
    
    for asset,balance of situation.latestBalances
        determineAvailableAsset(exchange, asset, balance)
    return

determineAvailableAsset = (exchange, asset, balance) ->
    availableAssets = availableBudgets[exchange]
    availableAssets[asset] = balance
    
    inUse = 0
    for strategy,strategyBudget of allBudgets
        inUse += assetsInUse(strategyBudget, exchange, asset)
    
    availableAssets[asset] -= inUse
    return

assetsInUse = (strategyBudget, exchange, asset) ->
    return 0 unless strategyBudget[exchange]?
    return 0 unless strategyBudget[exchange][asset]?
    assetBudget = strategyBudget[exchange][asset]
    if assetBudget.inUse? then return assetBudget.inUse
    return 0

#endregion

############################################################
assertBudgetExists = (strategy, exchange, asset) ->
    if !allBudgets[strategy]? then allBudgets[strategy] = {}
    exchangeBudgetMap = allBudgets[strategy]

    if !exchangeBudgetMap[exchange]? then exchangeBudgetMap[exchange] = {}
    assetBudgetMap = exchangeBudgetMap[exchange]

    if !assetBudgetMap[asset]? then assetBudgetMap[asset] = {}
    return

getAssetBudget = (strategy, exchange, asset) ->
    # log "getAssetBudget" + "("+strategy+","+exchange+","+asset+")"
    assertBudgetExists(strategy, exchange, asset)
    return allBudgets[strategy][exchange][asset]

#endregion

############################################################
#region exposedFunctions
budgetmanagermodule.freeAllBudgetsForStrategy = (strategy) ->
    # log "budgetmanagermodule.freeAllBudgetsStrategy"
    return unless allBudgets[strategy]?
    strategyBudget = allBudgets[strategy]
    
    for exchange,exchangeBudget of strategyBudget
        for asset,budget of exchangeBudget
            if budget.inUse? then budget.inUse = 0
    return

budgetmanagermodule.allocate = (strategy, exchange, asset, volume) ->
    msg = "allocate: "+budgetNumber(volume)+" "+asset 
    activityLog(msg) unless strategy == "none"
    
    volume = budgetNumber(volume)
    assetBudget = getAssetBudget(strategy, exchange, asset)
    
    available = availableBudgets[exchange][asset]
    if volume > available then throw new Error("Volume of "+volume+" "+asset+" surpasses the available "+available+" in the exchange!")
    if !assetBudget.inUse? then assetBudget.inUse = 0.0
    if assetBudget.max?
        legallyAvailable = assetBudget.max - assetBudget.inUse
        if volume > legallyAvailable then throw new Error("Volume of "+volume+" "+asset+" surpasses the legally available "+legallyAvailable+"!")

    assetBudget.inUse += volume
    assetBudget.inUse = budgetNumber(assetBudget.inUse)

    save()
    return

budgetmanagermodule.free = (strategy, exchange, asset, volume) ->
    msg = "free: "+budgetNumber(volume)+" "+asset 
    activityLog(msg)
    

    volume = budgetNumber(volume)
    assetBudget = getAssetBudget(strategy, exchange, asset)

    try
        if !assetBudget.inUse then throw new Error("Tried to free asset which is not inUse!")
        if assetBudget.inUse < volume then throw new Error("We have "+assetBudget.inUse+" inUse of "+asset+" but want to free "+volume+"!")
    catch err
        log err.stack
        assetBudget.inUse = volume

    assetBudget.inUse -= volume
    assetBudget.inUse = budgetNumber(assetBudget.inUse)

    save()
    return

budgetmanagermodule.registerTrade = (strategy, exchange, assetPair, volumeDif1, volumeDif2) ->
    # log "budgetmanagermodule.registerTrade"
    volumeDif1 = budgetNumber(volumeDif1)
    volumeDif2 = budgetNumber(volumeDif2)

    assets = assetPair.split("-")
    asset1Budget = getAssetBudget(strategy, exchange, assets[0])
    asset2Budget = getAssetBudget(strategy, exchange, assets[1])

    msg = "trade: "+budgetNumber(volumeDif1)+" "+assets[0]+" | "+budgetNumber(volumeDif2)+" "+assets[1]
    activityLog(msg)

    if !asset1Budget.inUse? then asset1Budget.inUse = 0.0
    if !asset2Budget.inUse? then asset2Budget.inUse = 0.0
    if !asset1Budget.dif? then asset1Budget.dif = 0.0
    if !asset2Budget.dif? then asset2Budget.dif = 0.0

    try
        if asset1Budget.inUse + volumeDif1 < 0 then throw new Error("Traded away asset which was not in use!")
        if asset2Budget.inUse + volumeDif2 < 0 then throw new Error("Traded away asset which was not in use!")
    catch err
        log err.stack
        if (asset1Budget.inUse + volumeDif1) < 0
            asset1Budget.inUse -= (asset1Budget.inUse + volumeDif1)
        if (asset2Budget.inUse + volumeDif2) < 0
            asset2Budget.inUse -= (asset2Budget.inUse + volumeDif2)

    asset1Budget.inUse += volumeDif1
    asset1Budget.inUse = budgetNumber(asset1Budget.inUse)
    asset1Budget.dif += volumeDif1
    asset1Budget.dif = budgetNumber(asset1Budget.dif)
    
    asset2Budget.inUse += volumeDif2
    asset2Budget.inUse = budgetNumber(asset2Budget.inUse)
    asset2Budget.dif += volumeDif2
    asset2Budget.dif = budgetNumber(asset2Budget.dif)
    
    save()
    return

budgetmanagermodule.updateAvailableBudgets = ->
    # log "budgetmanagermodule.updateAvailableBudgets"
    summarizeAvailableBudget()
    return

budgetmanagermodule.printCurrentBudgets = ->
    # log "availableBudgets:"
    # olog availableBudgets
    # log "allBudgets:"
    # olog allBudgets
    # log " - - - "
    return

############################################################
budgetmanagermodule.getAllBudgets = -> allBudgets
budgetmanagermodule.getActivityLog = -> allLogs.logs

# budgetmanagermodule.registerProfit = (strategy, exchange, asset, volume) ->
#     # log "budgetmanagermodule.registerProfit"
#     assetBudget = getAssetBudget(strategy, exchange, asset)
#     if !assetBudget.profit? then assetBudget.profit = 0.0
#     assetBudget.profit += volume
#     save()
#     return

# budgetmanagermodule.setBudgetInUse = (strategy, exchange, asset, volume) ->
#     log "budgetmanagermodule.setBudgetInUse"
#     assetBudget = getAssetBudget(strategy, exchange, asset)
#     assetBudget.inUse = volume
#     save()
#     return

#endregion

module.exports = budgetmanagermodule
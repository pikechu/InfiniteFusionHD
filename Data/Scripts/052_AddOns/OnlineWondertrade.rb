# Keep the class for existing map events; the obsolete localhost service is gone.
# The separate offline pbWonderTrade implementation is unchanged.
class OnlineWondertrade
  def pbWonderTrade
    pbMessage(_INTL("The old online Wonder Trade service has been retired. Offline Wonder Trade is still available at the trade center. Use Online Mode for the online trade pool."))
    nil
  end
end

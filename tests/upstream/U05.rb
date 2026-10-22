check = UpstreamTest.method(:check)
event = $data_common_events[COMMON_EVENT_FIX_GAME]
check.call(event && event.list.any? && event.name.downcase.include?("fix"), "compiled repair common event exists at the configured ID")
events = []
UpstreamTest.override(Kernel.singleton_class, :pbMessage, proc { |*| }) do
  UpstreamTest.override(Kernel.singleton_class, :pbStartOver, proc { |value| events << [:restart, value] }) do
    UpstreamTest.override(Object, :pbCommonEvent, proc { |id| events << [:repair, id] }) do
      UpstreamTest.override($game_player.singleton_class, :cancelMoveRoute, proc { events << [:cancel_route] }) do
        UpstreamTest.override(Kernel.singleton_class, :pbConfirmMessageSerious, proc { |*| false }) do
          check.call(ItemHandlers.triggerUseFromBag(:DEBUGGER) == 0 && events.empty?, "cancel debugger leaves route and world untouched")
        end
        UpstreamTest.override(Kernel.singleton_class, :pbConfirmMessageSerious, proc { |*| true }) do
          check.call(ItemHandlers.triggerUseFromBag(:DEBUGGER) == 1, "confirmed debugger returns success to bag")
          check.call(events == [[:cancel_route], [:restart, false], [:repair, COMMON_EVENT_FIX_GAME]], "debugger repairs only after cancelling route and resetting position")
        end
      end
    end
  end
end
check.call(GameData::Item.get(:DEBUGGER).is_key_item?, "debugger remains a reusable key item")

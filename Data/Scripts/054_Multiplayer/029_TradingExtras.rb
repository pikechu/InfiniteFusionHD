module KIFMultiplayer
  class TradingExtrasClient
    def initialize(client);@client=client;@trading=TradingClient.new(client);end
    def response(method,path,body=nil)
      value=@client.request(method,'/v1/market/'+path,body)
      @trading.check(value.is_a?(Hash) && value['ok']==true)
      value
    end
    def list(path,key,limit=100)
      values=response('GET',path)[key]
      @trading.check(values.is_a?(Array) && values.length<=limit && values.all? { |value| value.is_a?(Hash) })
      values.each { |value| @trading.identifier(value['id']) }
      values
    end
    def notices;list('notifications','notifications');end
    def searches;list('saved-searches','searches',20);end
    def mail
      values=list('mail','mail')
      values.each do |value|
        @trading.check([value['sender_id'],value['recipient_id']].include?(@client.player_id) && %w[pending claimed returned expired].include?(value['status']))
        @trading.check(value['subject'].is_a?(String) && value['subject'].length.between?(1,80) && value['text'].is_a?(String) && value['text'].length<=500)
        bundle=value['bundle'];@trading.check(bundle.is_a?(Hash) && bundle['asset_ids'].is_a?(Array) && bundle['asset_ids'].length<=6 && bundle['items'].is_a?(Hash) && bundle['items'].length<=8)
        bundle['asset_ids'].each { |id| @trading.identifier(id) };@trading.amount(bundle['coins'])
        bundle['items'].each { |id,count| Snapshot.registry(:Item,id);@trading.item_quantity(count,1) }
      end
      values
    end
    def save_search(name,filters,sort,alerts)
      response('POST','saved-searches',{'name'=>name,'query'=>{'filters'=>filters,'sort'=>sort},'alerts'=>alerts})['search']
    end
    def history(kind,key)
      value=@client.raw_request('POST','/v1/market/history',{'kind'=>kind,'key'=>key,'days'=>30})
      @trading.check(value['ok']==true && value['history'].is_a?(Array) && value['history'].length<=31)
      @trading.check([true,false].include?(value['sufficient_sample']) && [true,false].include?(value['truncated']) && value['trades'].is_a?(Integer) && value['trades'].between?(0,5000))
      value['history'].each do |day|
        @trading.check(day.is_a?(Hash) && %w[day open close low high quantity total trades weighted_average].all? { |key| day[key].is_a?(Integer) && day[key]>=0 } && day['quantity']>0 && day['trades']>0)
        @trading.check(day['weighted_average']==day['total']/day['quantity'] && day['low']<=day['high'])
      end
      value
    end
    def action(path,action,body={})
      parts=path.split('/');@trading.check(parts.length==2 && %w[mail saved-searches notifications contracts].include?(parts[0]))
      @trading.identifier(parts[1]);response('POST',path+(action.empty? ? '' : '/'+action),body)
    end
    def validate_contract(value)
      @trading.check(value.is_a?(Hash) && %w[auction buy_order training rental loan].include?(value['kind']) && %w[open active completed cancelled expired defaulted returned].include?(value['status']))
      %w[id owner_id].each { |key| @trading.identifier(value[key]) }
      @trading.check(value['revision'].is_a?(Integer) && value['revision']>0 && value['terms'].is_a?(Hash) && value['compatibility'].is_a?(Hash))
      %w[created_at expires_at server_time].each { |key| @trading.check(value[key].is_a?(Numeric) && value[key].finite? && value[key]>=0) }
      Snapshot.validate(value['snapshot']) if value['snapshot']
      Snapshot.validate(value['collateral_snapshot']) if value['collateral_snapshot']
      value
    end
    def contracts(kind,cursor=nil)
      value=@client.raw_request('POST','/v1/market/contracts/search',{'kind'=>kind,'cursor'=>cursor})
      @trading.check(value['ok']==true && value['contracts'].is_a?(Array) && value['contracts'].length<=20 && (value['next_cursor'].nil? || value['next_cursor'].is_a?(Hash)))
      value['contracts'].each { |entry| validate_contract(entry) };value
    end
    def contract(id)
      value=validate_contract(response('GET','contracts/'+@trading.identifier(id))['contract'])
      @trading.check(value['id']==id);value
    end
    def create_contract(kind,terms)
      validate_contract(response('POST','contracts',{'kind'=>kind,'terms'=>terms,'compatibility'=>@client.compatibility})['contract'])
    end
    def contract_action(value,action,body={})
      validate_contract(value)
      result=action('contracts/'+value['id'],action,body.merge('revision'=>value['revision'],'compatibility'=>@client.compatibility))
      updated=validate_contract(result['contract']);@trading.check(updated['id']==value['id']);updated
    end
  end

  class TradingExtrasUI
    KINDS={'auction'=>'竞价拍卖','buy_order'=>'求购订单','training'=>'代练服务','rental'=>'精灵租赁','loan'=>'抵押借贷'}.freeze
    def initialize(client)
      @client=client;@base=TradingUI.new(client);@ui=UI.new(client);@sdk=TradingExtrasClient.new(client)
    end
    def text(value);KIFMultiplayer.display_text(value);end
    def choose(title,choices);@ui.choose(title,choices);end
    def main
      loop do
        selected=choose('更多交易功能',['成交历史','收藏搜索／到货提醒','站内通知','资产邮件','竞价拍卖','求购订单','代练服务','精灵租赁','抵押借贷','我的合同','待收款','返回'])
        return if selected<0 || selected>=11
        @ui.perform do
          case selected
          when 0 then price_history
          when 1 then saved_searches
          when 2 then notifications
          when 3 then mail
          when 4..8 then contract_market(KINDS.keys[selected-4])
          when 9
            values=@sdk.list('contracts','contracts').map { |entry| @sdk.validate_contract(entry) }
            index=choose('我的合同',values.map { |v| contract_label(v) }+['返回'])
            contract_detail(values[index]) if index>=0 && index<values.length
          when 10
            value=@sdk.response('GET','cash')
            @sdk.response('POST','cash') if value['cash']>0 && pbConfirmMessage("待收款 #{value['cash']} 联机币。领取到钱包可用容量？")
          end
        end
      end
    end
    def save_search(filters,sort)
      name=@ui.enter('为此搜索命名；留空返回','',40);return if name.empty?
      @sdk.save_search(name,filters,sort,pbConfirmMessage('符合条件的新挂牌到货时，生成站内提醒？'))
      pbMessage('已保存。提醒在服务器保存，断线后仍可查看。')
    end
    def saved_searches
      loop do
        values=@sdk.searches
        selected=choose('收藏搜索',values.map { |v| "#{text(v['name'])} · 提醒#{v['alerts'] ? '开' : '关'}" }+['新建','返回'])
        return if selected<0 || selected>values.length
        if selected==values.length
          category=choose('搜索类型',['精灵','道具','返回']);next if category<0 || category>1
          save_search(@base.filters_menu({'category'=>category==0 ? 'pokemon' : 'item'}),'price_asc');next
        end
        value=values[selected]
        action=choose(text(value['name']),['执行搜索','切换提醒','删除','返回']);next if action<0 || action>2
        if action==0
          query=value['query'];@base.market(query['filters'].fetch('category','pokemon'),query['filters'],query.fetch('sort','price_asc'))
        else
          @sdk.action('saved-searches/'+value['id'],'',action==1 ? {'alerts'=>!value['alerts']} : {'delete'=>true})
        end
      end
    end
    def notifications
      loop do
        values=@sdk.notices
        selected=choose('站内通知',values.map { |v| "#{v['read'] ? '' : '[未读]'} #{text(v['kind'])} · #{text(v['data']['name'] || v['data']['subject'] || v['data']['status'])}" }+['全部已读','返回'])
        return if selected<0 || selected>values.length
        if selected==values.length
          @sdk.action('notifications/read-all','');next
        end
        value=values[selected];@sdk.action('notifications/'+value['id'],'')
        if value['kind']=='arrival'
          @base.listing_menu(@base.instance_variable_get(:@trading).listing(value['data']['listing_id']))
        else
          pbMessage(text(WireJSON.dump(value['data'])))
        end
      end
    end
    def price_history
      category=choose('查看最近30天实际成交',['精灵','道具','返回']);return if category<0 || category>1
      key=@ui.enter('输入名称／ID','',80);return if key.empty?
      id=@base.resolve_id(category==0 ? :Species : :Item,key);return unless id
      value=@sdk.history(category==0 ? 'pokemon' : 'item',id)
      pbMessage("符合口径成交 #{value['trades']} 笔。#{value['sufficient_sample'] ? '' : '样本不足。'}\n剔除相互反向成交及不兼容规则；实际成交记录不等于市场估值。#{value['truncated'] ? '仅统计最新5000笔范围。' : ''}")
      value['history'].each do |day|
        pbMessage("#{Time.at(day['day']*86400).utc.strftime('%Y-%m-%d')}\n成交#{day['trades']}笔／#{day['quantity']}个\n最低#{day['low']} 最高#{day['high']}\n加权均价#{day['weighted_average']}")
      end
    end
    def bundle
      ids=[];items={};coins=0
      loop do
        choice=choose("邮件附件：#{ids.length}只精灵／#{items.length}种道具／#{coins}币",['选择精灵','添加道具','联机币','完成','取消'])
        return nil if choice<0 || choice>=4
        return {'asset_ids'=>ids,'items'=>items,'coins'=>coins} if choice==3
        if choice==0
          values=@base.instance_variable_get(:@trading).assets.select { |v| !v['locked'] }
          index=choose('精灵点选／取消',values.map { |v| "#{ids.include?(v['id']) ? '[已选]' : ''} #{@base.label(v)}" }+['返回'])
          next if index<0 || index>=values.length
          id=values[index]['id'];ids.include?(id) ? ids.delete(id) : ids<<id
          raise Error,'最多六只精灵。' if ids.length>6
        elsif choice==1
          values=@base.instance_variable_get(:@trading).inventory['items'].select { |v| v['available']>0 && v['item']['tradeable'] }
          index=choose('选择道具',values.map { |v| "#{text(v['item']['name'])} 可用#{v['available']}" }+['返回']);next if index<0 || index>=values.length
          value=values[index];count=@base.number('数量；0删除',items[value['item_id']] || 0);next unless count
          raise Error,'数量超过库存。' if count>value['available']
          count==0 ? items.delete(value['item_id']) : items[value['item_id']]=count
          raise Error,'最多八种道具。' if items.length>8
        else
          coins=@base.number('联机币数量',coins) || coins
        end
      end
    end
    def mail
      loop do
        values=@sdk.mail
        index=choose('资产邮件',values.map { |v| "#{v['recipient_id']==@client.player_id ? '收' : '发'} · #{text(v['subject'])} · #{text(v['status'])}" }+['写信','返回'])
        return if index<0 || index>values.length
        if index==values.length
          code=@ui.enter('收件人好友码','',8);next if code.empty?
          subject=@ui.enter('主题','',80);next if subject.empty?
          body=@ui.enter('正文','',500);attachments=bundle;next unless attachments
          next unless pbConfirmMessage("发给 #{text(code)}？\n附件进入服务器预留，30天未收取自动退回，可在收取前取消。")
          @sdk.response('POST','mail',attachments.merge('friend_code'=>code,'subject'=>subject,'text'=>body,'compatibility'=>@client.compatibility));next
        end
        value=values[index];attachment=value['bundle']
        pbMessage("#{text(value['subject'])}\n#{text(value['text'])}\n#{attachment['asset_ids'].length}只精灵／#{text(WireJSON.dump(attachment['items']))}／#{attachment['coins']}币")
        next unless value['status']=='pending'
        own=value['sender_id']==@client.player_id
        action=choose('邮件操作',own ? ['取消并退回','返回'] : ['收取附件','拒收并退回','返回'])
        next if action<0 || action>=(own ? 1 : 2)
        @sdk.action('mail/'+value['id'],own ? 'cancel' : action==0 ? 'claim' : 'reject') if pbConfirmMessage('确认此邮件操作？')
      end
    end
    def contract_label(value)
      terms=value['terms'];summary=case value['kind']
      when 'auction' then "当前总价#{value['bid'].to_i>0 ? value['bid'] : terms['start_price']}"
      when 'buy_order' then "剩#{value['remaining']} · 单价#{terms['unit_price']}"
      when 'training' then "目标Lv.#{terms['level']} · 报酬#{terms['reward']}"
      when 'rental' then "租金#{terms['fee']} · #{terms['duration']/3600}小时"
      else "本金#{terms['principal']} · 还款#{terms['repayment']}"
      end
      "#{KINDS[value['kind']]} · #{summary} · #{text(value['status'])}"
    end
    def contract_market(kind)
      cursor=nil
      loop do
        page=@sdk.contracts(kind,cursor);values=page['contracts']
        index=choose(KINDS[kind],values.map { |v| contract_label(v) }+['下一页','第一页','发布','返回'])
        return if index<0 || index>=values.length+3
        if index<values.length then contract_detail(values[index])
        elsif index==values.length then cursor=page['next_cursor'] || cursor
        elsif index==values.length+1 then cursor=nil
        else create_contract(kind)
        end
      end
    end
    def pick_contract_asset
      values=@base.instance_variable_get(:@trading).assets.reject { |v| v['locked'] }
      index=choose('选择服务器可用精灵',values.map { |v| @base.label(v) }+['返回'])
      index>=0 && index<values.length ? values[index] : nil
    end
    def required_number(prompt,initial=0,minimum=1)
      value=@base.number(prompt,initial,minimum)
      raise Error,'已取消填写。' if value.nil?
      value
    end
    def create_contract(kind)
      hours=required_number('挂牌有效小时数（1～168）',24)
      terms={'offer_seconds'=>hours*3600}
      case kind
      when 'auction'
        type=choose('拍卖类型',['精灵','道具','返回']);return if type<0 || type>1
        if type==0
          asset=pick_contract_asset;return unless asset
          @base.inspect_asset(asset);terms['asset_id']=asset['id']
        else
          id=@base.resolve_id(:Item,@ui.enter('道具名称／ID','',80));return unless id
          terms.merge!('item_id'=>id,'quantity'=>required_number('整组拍卖数量',1))
        end
        terms.merge!('start_price'=>required_number('起拍总价'),'increment'=>required_number('每次最低加价',100))
      when 'buy_order'
        type=choose('求购类型',['精灵','道具','返回']);return if type<0 || type>1
        terms['category']=type==0 ? 'pokemon' : 'item'
        if type==0 then terms['filters']=@base.filters_menu({'category'=>'pokemon'})
        else
          terms['item_id']=@base.resolve_id(:Item,@ui.enter('道具名称／ID','',80));return unless terms['item_id']
        end
        terms.merge!('quantity'=>required_number('求购总数量',1),'unit_price'=>required_number('每只／每件支付价格'))
      when 'training','rental'
        asset=pick_contract_asset;return unless asset
        @base.inspect_asset(asset)
        terms.merge!('asset_id'=>asset['id'],'duration'=>required_number('接单后服务／租赁小时数',24)*3600,'bond'=>required_number('接单方保证金；0为不收取',0,0))
        if kind=='training'
          terms['reward']=required_number('达到目标后的报酬')
          terms['level']=required_number('目标等级',asset['snapshot']['level'])
          terms['ev_min']={}
          loop do
            index=choose('EV最低目标（可留空）',Snapshot::STATS+['完成']);break if index<0 || index>=6
            terms['ev_min'][Snapshot::STATS[index]]=required_number('最低EV（0～252）',0,0)
          end
        else
          terms['fee']=required_number('一次性租金（提前归还不退）')
        end
      else
        terms['principal']=required_number('借出的本金')
        terms['repayment']=required_number('固定还款总额（本金～本金的110%）',terms['principal'])
        terms['duration']=required_number('借款期限小时数（1～720）',24)*3600
        terms['filters']=@base.filters_menu({'category'=>'pokemon'})
        if terms['filters'].key?('min_price') || terms['filters'].key?('max_price')
          raise Error,'抵押条件只按精灵属性核对，不提供自动估值；请移除价格筛选后重新发布。'
        end
      end
      pbMessage("#{KINDS[kind]} 条款\n#{text(WireJSON.dump(terms))}\n发布费按基准金额2%收取，最低100、最高25000。")
      return unless pbConfirmMessage('按上述条款发布？资金／精灵／道具将由服务器预留。')
      result=@sdk.create_contract(kind,terms)
      pbMessage("已发布 #{text(result['id'])}。")
    end
    def contract_detail(initial)
      loop do
        value=@sdk.contract(initial['id']);terms=value['terms'];own=value['owner_id']==@client.player_id
        pbMessage("#{contract_label(value)}\n#{text(WireJSON.dump(terms))}\n截止UTC #{Time.at(value['expires_at']).utc.strftime('%m-%d %H:%M')}\n#{text(value['id'])}")
        @base.inspect_asset({'id'=>value['bundle']['asset_ids'][0],'snapshot'=>value['snapshot']}) if value['snapshot']
        @base.inspect_asset({'id'=>value['collateral_id'],'snapshot'=>value['collateral_snapshot']}) if value['collateral_snapshot']
        choices=[]
        if value['status']=='open'
          choices<<['取消挂牌','cancel'] if own && !(value['kind']=='auction' && value['bid'].to_i>0)
          choices<<[{ 'auction'=>'出价','buy_order'=>'供货','training'=>'承接代练','rental'=>'租用','loan'=>'抵押借款'}[value['kind']],{'auction'=>'bid','buy_order'=>'fill'}.fetch(value['kind'],'accept')] unless own
        elsif value['status']=='active'
          holder=value['counterparty_id']==@client.player_id
          choices<<['验收并完成代练','finish'] if value['kind']=='training'
          choices<<[value['kind']=='training' ? '中止归还（未达标扣除保证金）' : '归还租用精灵（租金不退）','return'] if holder && %w[training rental].include?(value['kind'])
          choices<<['偿还固定金额并取回抵押','repay'] if holder && value['kind']=='loan'
        end
        index=choose('合同操作',choices.map(&:first)+['刷新','返回']);return if index<0 || index>choices.length
        next if index==choices.length
        action=choices[index][1];body={}
        if action=='bid'
          minimum=value['bid'].to_i>0 ? value['bid']+terms['increment'] : terms['start_price']
          body['amount']=required_number('出价总额；成为最高价后冻结该金额',minimum)
        elsif action=='fill'
          if terms['category']=='item' then body['quantity']=required_number('供应数量',1)
          else
            asset=pick_contract_asset;return unless asset
            @base.inspect_asset(asset);body['asset_id']=asset['id']
          end
        elsif action=='accept' && value['kind']=='loan'
          pbMessage("到期未还款，抵押精灵将永久归出借人；还款额为#{terms['repayment']}联机币。没有自动估价，请自行核对抵押条件。")
          asset=pick_contract_asset;return unless asset
          @base.inspect_asset(asset);body['asset_id']=asset['id']
        elsif action=='accept'
          pbMessage(value['kind']=='training' ? '代练只能通过服务端培养和战斗提升。达到目标后才能领取报酬；未达标中止或超时会扣除保证金，精灵自动归还。' : '租金支付后不退，保证金归还时释放。租用精灵不能转卖、融合、繁育、释放或变更携带物，到期自动归还。')
        end
        next unless pbConfirmMessage('确认按当前完整条款执行？')
        result=@sdk.contract_action(value,action,body)
        pbMessage("操作完成：#{text(result['status'])}。归还／购入资产可在待领取收纳。")
      end
    end
  end
end

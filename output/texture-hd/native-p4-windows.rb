directory=File.expand_path('output/texture-hd/p4-evidence');log=File.join(directory,'windows-result.txt');passed=false
begin
 File.write(log,"P4_WINDOWS_BEGIN\n");load 'scripts/multiplayer/test-bootstrap.rb'
 Graphics.resize_screen(512,384);Graphics.frame_rate=40;$GameSpeed=1
 rows=KIFMultiplayer::WireJSON.parse(File.binread('output/texture-hd/p4-work/native-index.json'),49*1024*1024,3000000).select { |r| r['stage']=='windows' }
 module P4WindowClock
  def frame_count;return $p4_window_frame if $p4_window_frame;super;end
 end
 Graphics.singleton_class.prepend(P4WindowClock)
 inputs={};states=[];sidecars={};captures=[];closed_state_issue=nil;compatibility=[]
 probe=SpriteWindow_Base.new(24,48,384,160)
 begin
  probe.openness=0
 rescue RangeError => error
  closed_state_issue={'issue'=>'Existing zero-openness component divides zero offset by zero zoom before native Sprite position assignment',
   'error'=>error.message,'scope'=>'Generic SpriteWindow; source images were unchanged. Nonzero openness states tested below.'}
 ensure
  probe.dispose
 end
 [0,2].each do |language|
  GameLanguage.load(language)
  rows.each_with_index do |row,index|
   source=row['source'];inputs[source]=Digest::SHA256.hexdigest(File.binread(source))
   txt=source.sub(/\.[^.]+\z/,'.txt');sidecars[txt]=Digest::SHA256.hexdigest(File.binread(txt)) if File.file?(txt)
   window=SpriteWindow_Base.new(24,48,384,160);window.setSkin(source.sub(/\.[^.]+\z/,''));window.contents=Bitmap.new(600,300)
   if [window.windowskin.width,window.windowskin.height]!=row['size'] && source=='Graphics/Windowskins/Windowskin.PNG'
    compatibility << {'source'=>source,'issue'=>'Uppercase PNG suffix is rejected by full-path resolver; stem resolves lowercase extension which the native virtual filesystem does not load. Explicit original-case AnimatedBitmap loads 192x128 correctly.'} if language==0
    owner=AnimatedBitmap.new(source);window.instance_variable_set(:@customskin,owner);window.__setWindowskin(owner.bitmap)
   end
   pbSetSystemFont(window.contents);window.contents.draw_text(0,0,380,40,language==2 ? '物品 100/100' : 'ITEMS 100/100')
   raise "Skin not loaded #{source}: expected #{row['size']} got #{[window.windowskin.width,window.windowskin.height]}" unless [window.windowskin.width,window.windowskin.height]==row['size']
   window.pause=true;window.compat|=SpriteWindow::CompatBits::ShowScrollArrows|SpriteWindow::CompatBits::ShowPause|SpriteWindow::CompatBits::ShowCursor
   window.cursor_rect.set(8,8,96,32);window.ox=12;window.oy=10
   [[224,96],[384,160]].each do |width,height|
    window.width=width;window.height=height
    [1,128,255].each do |openness|
     window.openness=openness;trace=[]
     65.times do |frame|
      $p4_window_frame=frame;window.update
      pause=window.instance_variable_get(:@sprites)['pause'];cursor=window.instance_variable_get(:@sprites)['cursor']
      raise 'Invalid cursor extent' unless cursor.src_rect.width>=0 && cursor.src_rect.height>=0
      trace << [window.instance_variable_get(:@pauseframe),pause.src_rect.x,pause.src_rect.y,cursor.opacity]
     end
     raise 'Pause cycle incomplete' unless trace.map(&:first).uniq.sort==[0,1,2,3] && trace.first[0,3]==trace.last[0,3]
     states << [source,language,width,height,openness,window.skinformat,trace]
    end
   end
   window.openness=255
   if index%12==0
    $p4_window_frame=nil;Graphics.update;bitmap=Graphics.snap_to_bitmap
    name="windows-#{language}-#{index}.png";bitmap.to_file(File.join(directory,name));bitmap.dispose;captures << name
   end
   window.dispose
  end
 end
 $p4_window_frame=nil
 scripts=['Data/Scripts/007_Objects and windows/003_Window.rb','Data/Scripts/007_Objects and windows/004_SpriteWindow.rb',
  'Data/Scripts/007_Objects and windows/002_MessageConfig.rb','Data/Scripts/007_Objects and windows/008_AnimatedBitmap.rb',
  'Data/localization/zh-CN-images.json','Data/Scripts/001_Technical/002_Files/001_FileTests.rb',
  'Data/Scripts/007_Objects and windows/001_RPG_Cache.rb']
 doc={'status'=>'passed','inputs'=>inputs,'sidecar_sha256'=>sidecars,'states'=>states,'captures'=>captures,'closed_state_issue'=>closed_state_issue,'compatibility_issues'=>compatibility,
  'script_sha256'=>scripts.to_h { |p| [p,Digest::SHA256.hexdigest(File.binread(p))] },
  'scope'=>'82 skins through SpriteWindow_Base.setSkin and one uppercase-extension compatibility source via explicit original-case AnimatedBitmap plus the same window compositor; original files retained. Actual XP/VX/custom formats and sidecars, two sizes, nonzero openness 1/128/255, scroll/cursor and complete pause/cursor cycles under a deterministic clock, in English/Chinese. Existing generic zero-openness RangeError and uppercase resolver mismatch are separately reported without changing game code. Not every dialogue/event or all text content.'}
 encoded=KIFMultiplayer::WireJSON.encode(doc,0);raise 'Report exceeds 49MiB' if encoded.bytesize>49*1024*1024
 File.write(File.join(directory,'windows-review.json'),encoded);File.open(log,'a'){ |f| f.puts("P4_WINDOWS_PASS inputs=#{inputs.length} states=#{states.length}") };passed=true
rescue Exception => error
 File.open(log,'a'){ |f| f.puts("P4_WINDOWS_FAIL #{error.class}: #{error.message.to_s[0,1600]}\n#{error.backtrace.first(8).join("\n")}") }
ensure
 $p4_window_frame=nil;exit!(passed ? 0 : 1)
end

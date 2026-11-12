import AppKit
import AVFoundation
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
if CommandLine.arguments.count < 2 {
 Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { _ in app.terminate(nil) }
 app.run()
 exit(0)
}
let player = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
player.numberOfLoops = -1; player.volume = 0.02; player.prepareToPlay(); player.play()
DispatchQueue.global().async {
 while let command = readLine() {
  DispatchQueue.main.async {
   switch command { case "play": player.play(); case "pause": player.pause(); default: app.terminate(nil) }
  }
 }
 DispatchQueue.main.async { app.terminate(nil) }
}
app.run()

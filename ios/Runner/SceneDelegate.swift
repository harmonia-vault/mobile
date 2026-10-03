import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  private var shield: UIView?
  private var locked = false
  private var unlocking = false
  private var bridge: NativeBridgePlugin? { (UIApplication.shared.delegate as? AppDelegate)?.nativeBridge }

  override func sceneWillResignActive(_ scene: UIScene) {
    cover()
    super.sceneWillResignActive(scene)
  }
  override func sceneDidEnterBackground(_ scene: UIScene) {
    locked = true
    bridge?.enterBackground()
    super.sceneDidEnterBackground(scene)
  }
  override func sceneDidBecomeActive(_ scene: UIScene) {
    super.sceneDidBecomeActive(scene)
    if locked { unlock() } else { uncover() }
  }
  private func cover() {
    guard shield == nil, let window else { return }
    let cover = UIView(frame: window.bounds)
    cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    cover.backgroundColor = .systemBackground
    cover.isAccessibilityElement = true
    cover.accessibilityLabel = "和弦已锁定，轻点后使用系统认证解锁"
    cover.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(unlock)))
    window.addSubview(cover)
    shield = cover
  }
  private func uncover() { shield?.removeFromSuperview(); shield = nil }
  @objc private func unlock() {
    guard !unlocking else { return }
    guard let bridge else { return }
    unlocking = true
    bridge.unlockPrivacy { [weak self] success in
      guard let self else { return }
      self.unlocking = false
      if success { self.locked = false; self.uncover() }
    }
  }
}

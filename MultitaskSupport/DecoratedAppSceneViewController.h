#import "FoundationPrivate.h"
#import "AppSceneViewController.h"

API_AVAILABLE(ios(16.0))
@interface DecoratedAppSceneViewController : UIViewController<AppSceneViewControllerDelegate>
@property(nonatomic) AppSceneViewController* appSceneVC;
@property(nonatomic) UIStackView *view;
@property(nonatomic) UINavigationBar *navigationBar;
@property(nonatomic) UINavigationItem *navigationItem;
@property(nonatomic) UIView *resizeHandle;
@property(nonatomic) UIView* contentView;

@property(nonatomic) BOOL isMaximized;
@property(nonatomic) CGFloat scaleRatio;
// YES while this window is pinned to the immersive fullscreen mode
// (LCLaunchMultitaskMaximized). In that mode the guest scene covers the whole
// screen and the home bar has to be handled inside the guest process.
@property(nonatomic, readonly) BOOL immersiveFullscreen;
- (instancetype)initWindowName:(NSString*)windowName bundleId:(NSString*)bundleId dataUUID:(NSString*)dataUUID rootVC:(UIViewController*)rootVC;
- (void)minimizeWindow;
- (void)closeWindow;
- (void)minimizeWindowPiP;
- (void)unminimizeWindowPiP;
- (void)updateVerticalConstraints;
@property(nonatomic, copy) void (^pidAvailableHandler)(NSNumber *pid, NSError *error);
@end


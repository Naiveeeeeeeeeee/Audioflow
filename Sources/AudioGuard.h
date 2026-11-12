#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
BOOL SFPerformAudioOperation(void (NS_NOESCAPE ^operation)(void), NSError * _Nullable * _Nullable error);
void SFThrowAudioTestException(void);
NS_ASSUME_NONNULL_END

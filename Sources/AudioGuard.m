#import "AudioGuard.h"
BOOL SFPerformAudioOperation(void (NS_NOESCAPE ^operation)(void), NSError **error) {
    @try { operation(); return YES; }
    @catch (NSException *exception) {
        if (error) *error = [NSError errorWithDomain:@"SoundFlow.AudioHardware" code:1 userInfo:@{
            NSLocalizedDescriptionKey: [NSString stringWithFormat:@"音频设备初始化或连接中断：%@。请检查设备连接与输入／输出格式，然后重试。", exception.reason ?: exception.name]
        }];
        return NO;
    }
}
void SFThrowAudioTestException(void) {
    @throw [NSException exceptionWithName:@"SoundFlow.TestAudioException" reason:@"Input HW format is invalid (recovery test)" userInfo:nil];
}

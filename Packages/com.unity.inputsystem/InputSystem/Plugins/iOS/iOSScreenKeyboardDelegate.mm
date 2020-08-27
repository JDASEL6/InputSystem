#include "iOSScreenKeyboardDelegate.h"
#include "DisplayManager.h"
#include "UnityAppController.h"
#include "UnityForwardDecls.h"
#include <string>


#define ENABLE_KEYBOARD_LOG 0
#if ENABLE_KEYBOARD_LOG
#define KEYBOARD_LOG(...) NSLog(@__VA_ARGS__)
#else
#define KEYBOARD_LOG(...) {}
#endif


static iOSScreenKeyboardDelegate* s_Keyboard = nil;
static const unsigned kToolBarHeight = 40;
static const unsigned kSystemButtonsSpace = 2 * 60 + 3 * 18; // empirical value, there is no way to know the exact widths of the system bar buttons

@interface iOSScreenKeyboardDelegate ()
- (void)textDidChangeImpl: (NSString*) text;
- (void)selectionChangeImpl: (NSRange) range;
+ (NSRange)getSelectionFromTextInput:(UIView<UITextInput>*)textInput;
@end

@implementation iOSScreenKeyboardDelegate
{
    // UI handling
    // in case of single line we use UITextField inside UIToolbar
    // in case of multi-line input we use UITextView with UIToolbar as accessory view
    // toolbar buttons are kept around to prevent releasing them
    // tvOS does not support multiline input thus only UITextField option is implemented
#if PLATFORM_IOS
    UITextView*         m_TextView;
    UIToolbar*          m_ViewToolbar;
    NSArray*            m_ViewToolbarItems;
    NSLayoutConstraint* m_WidthConstraint;
    UIToolbar*          m_FieldToolbar;
    NSArray*            m_FieldToolbarItems;
#endif

    UITextField*        m_TextField;

    // inputView is view used for actual input (it will be responder): UITextField [single-line] or UITextView [multi-line]
    // editView is the "root" view for keyboard: UIToolbar [single-line] or UITextView [multi-line]
    UIView*             m_InputView;
    UIView*             m_EditView;

    iOSScreenKeyboardShowParamsNative m_ShowParams;

    CGRect              m_Area;
    NSString*           m_InitialText;

    BOOL                m_InputHidden;
    BOOL                m_Active;
    iOSScreenKeyboardStatus      m_Status;

    // not pretty but seems like easiest way to keep "we are rotating" status
    BOOL                m_Rotating;
    bool                m_ShouldHideInput;
    bool                m_ShouldHideInputChanged;
    
    NSRange             m_LastSelection;
}

@synthesize area;
//@synthesize active      = m_Active;
//@synthesize status      = m_Status;
//@synthesize text;
//@synthesize selection;


- (BOOL)textFieldShouldReturn:(UITextField*)textFieldObj
{
    [self textInputDone: nil];
    return YES;
}

- (void)textInputDone:(id)sender
{
    if (m_Status != StatusVisible)
        return;
    
    [self hide: StatusDone];
}

- (void)textInputCancel:(id)sender
{
    [self hide: StatusCanceled];
}

- (void)textInputLostFocus
{
    if (m_Status != StatusVisible)
        return;

    [self hide: StatusLostFocus];
}

- (void)textDidChangeImpl: (NSString*) text
{
    KEYBOARD_LOG("textDidChangeImpl %@", text);
    if (m_ShowParams.callbacks.textChangedCallback)
        m_ShowParams.callbacks.textChangedCallback(m_ShowParams.callbacks.deviceId, [text UTF8String]);
    else
        NSLog(@"textViewDidChange: Missing callback");
}

- (void)selectionChangeImpl: (NSRange) range
{
    KEYBOARD_LOG("selectionChangeImpl %u, %u", (unsigned int) range.location, (unsigned int) range.length);
    
    if (NSEqualRanges(m_LastSelection, range))
    {
        KEYBOARD_LOG("    selection hasn't changed, will not invoke callback");
        return;
    }
    m_LastSelection = range;
    if (m_ShowParams.callbacks.selectionChanagedCallback)
    {
        m_ShowParams.callbacks.selectionChanagedCallback(m_ShowParams.callbacks.deviceId, (int)range.location, (int)range.length);
    }
    else
        NSLog(@"selectionChanagedCallback: Missing callback");
}

- (void)textViewDidChange:(UITextView *)textView
{
    [self textDidChangeImpl: [textView text]];
}

- (void)textViewDidChangeSelection:(UITextView *)textView
{
    [self selectionChangeImpl: [iOSScreenKeyboardDelegate getSelectionFromTextInput: textView]];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if ([keyPath isEqualToString: @"selectedTextRange"] && m_TextField == object)
        [self selectionChangeImpl: [iOSScreenKeyboardDelegate getSelectionFromTextInput: m_TextField]];
}

// Note: This callback is available only from iOS 14.0 or higher
- (void)textFieldDidChangeSelection:(UITextField *)textField
{
    [self selectionChangeImpl: [iOSScreenKeyboardDelegate getSelectionFromTextInput: textField]];
}

- (void)textFieldDidChange:(UITextField*)textField
{
    // Note: Regarding selections
    //       When text changes in text view, textViewDidChangeSelection is triggered
    //       When text changes in text field, observeValueForKeyPath with selectedTextRange doesn't get triggered.
    //       When selection changes in text view, textViewDidChangeSelection is triggered
    //       When selection changes in text field, observeValueForKeyPath with selectedTextRange is triggered
    
    // Workaround issue with selection not being triggered
    if (@available(iOS 13.0, tvOS 13.0, *))
    {
        // Empty on purpose
    }
    else
    {
        [self selectionChangeImpl: [iOSScreenKeyboardDelegate getSelectionFromTextInput: m_TextField]];
    }
    [self textDidChangeImpl: textField.text];
}

- (BOOL)textViewShouldBeginEditing:(UITextView*)view
{
#if !PLATFORM_TVOS
    view.inputAccessoryView = m_ViewToolbar;
#endif
    return YES;
}

#if PLATFORM_IOS

- (void)keyboardWillShow:(NSNotification *)notification
{
    if (notification.userInfo == nil || m_InputView == nil)
        return;

    CGRect srcRect  = [[notification.userInfo objectForKey: UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGRect rect     = [UnityGetGLView() convertRect: srcRect fromView: nil];
    rect.origin.y = [UnityGetGLView() frame].size.height - rect.size.height; // iPhone X sometimes reports wrong y value for keyboard

    [self positionInput: rect x: rect.origin.x y: rect.origin.y];
}

- (void)keyboardDidShow:(NSNotification*)notification
{
    m_Active = YES;
}

- (void)keyboardWillHide:(NSNotification*)notification
{
    [self systemHideKeyboard];
}

- (void)keyboardDidChangeFrame:(NSNotification*)notification
{
    m_Active = true;

    CGRect srcRect  = [[notification.userInfo objectForKey: UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGRect rect     = [UnityGetGLView() convertRect: srcRect fromView: nil];

    if (rect.origin.y >= [UnityGetGLView() bounds].size.height)
        [self systemHideKeyboard];
    else
    {
        rect.origin.y = [UnityGetGLView() frame].size.height - rect.size.height; // iPhone X sometimes reports wrong y value for keyboard
        [self positionInput: rect x: rect.origin.x y: rect.origin.y];
    }
}

#endif

+ (iOSScreenKeyboardDelegate*)getInstanceOrCreate
{
    if (!s_Keyboard)
    {
        s_Keyboard = [[iOSScreenKeyboardDelegate alloc] init];
        s_Keyboard->m_ShouldHideInput = false;
        s_Keyboard->m_ShouldHideInputChanged = false;
    }

    return s_Keyboard;
}

+ (iOSScreenKeyboardDelegate*)getInstance
{
    return s_Keyboard;
}

- (void)show:(iOSScreenKeyboardShowParamsNative)param withInitialTextCStr:(const char*)initialTextCStr withPlaceholderTextCStr:(const char*)placeholderTextCStr
{
    if (!m_EditView.hidden)
    {
        [NSObject cancelPreviousPerformRequestsWithTarget: self];
        if (m_ShowParams.multiline != param.multiline ||
            m_ShowParams.secure != param.secure ||
            m_ShowParams.keyboardType != param.keyboardType ||
            m_ShowParams.autocorrectionType != param.autocorrectionType ||
            m_ShowParams.appearance != param.appearance)
        {
            [self hideUIDelayed];
        }
    }
    m_ShowParams = param;

    if (m_Active)
        [self hide: StatusDone];

    m_InitialText = initialTextCStr ? [[NSString alloc] initWithUTF8String: initialTextCStr] : @"";

    // TODO
    //_characterLimit = param.characterLimit;

    UITextAutocapitalizationType capitalization = UITextAutocapitalizationTypeSentences;
    if (param.keyboardType == UIKeyboardTypeURL || param.keyboardType == UIKeyboardTypeEmailAddress || param.keyboardType == UIKeyboardTypeWebSearch)
        capitalization = UITextAutocapitalizationTypeNone;

#if PLATFORM_IOS
    if (m_ShowParams.multiline)
    {
        m_TextView.text = m_InitialText;
        [self setTextInputTraits: m_TextView withParam: param withCap: capitalization];

        UITextPosition* end = [m_TextView endOfDocument];
        UITextRange* endTextRange = [m_TextView textRangeFromPosition: end toPosition: end];
        [m_TextView setSelectedTextRange: endTextRange];
    }
    else
#endif
    {
        m_TextField.text = m_InitialText;
        [self setTextInputTraits: m_TextField withParam: param withCap: capitalization];
        m_TextField.placeholder = placeholderTextCStr ? [NSString stringWithUTF8String: placeholderTextCStr] : @"";

        UITextPosition* end = [m_TextField endOfDocument];
        UITextRange* endTextRange = [m_TextField textRangeFromPosition: end toPosition: end];
        [m_TextField setSelectedTextRange: endTextRange];
    }

#if PLATFORM_IOS
    m_InputView = m_ShowParams.multiline ? m_TextView : m_TextField;
    m_EditView = m_ShowParams.multiline ? m_TextView : m_FieldToolbar;
#else
    m_InputView = m_TextField;
    m_EditView = m_TextField;
#endif
    // TODO
    //[self shouldHideInput: m_ShouldHideInput];

    m_LastSelection.length = 0;
    m_LastSelection.location = m_InitialText.length;
    
    m_Status     = StatusVisible;
    m_ShowParams.callbacks.statusChangedCallback(m_ShowParams.callbacks.deviceId, m_Status);
    m_Active     = YES;

    [self showUI];
}

-(void)hide: (iOSScreenKeyboardStatus)hideStatus
{
    m_Status     = hideStatus;
    m_ShowParams.callbacks.statusChangedCallback(m_ShowParams.callbacks.deviceId, m_Status);
    [self hideUI];
}

#if PLATFORM_IOS
struct CreateToolbarResult
{
    UIToolbar*  toolbar;
    NSArray*    items;
};

- (CreateToolbarResult)createToolbarWithView:(UIView*)view
{
    UIToolbar* toolbar = [[UIToolbar alloc] initWithFrame: CGRectMake(0, 840, 320, kToolBarHeight)];
    UnitySetViewTouchProcessing(toolbar, touchesIgnored);
    toolbar.hidden = NO;

    UIBarButtonItem* inputItem  = view ? [[UIBarButtonItem alloc] initWithCustomView: view] : nil;
    UIBarButtonItem* doneItem   = [[UIBarButtonItem alloc] initWithBarButtonSystemItem: UIBarButtonSystemItemDone target: self action: @selector(textInputDone:)];
    UIBarButtonItem* cancelItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem: UIBarButtonSystemItemCancel target: self action: @selector(textInputCancel:)];

    NSArray* items = view ? @[inputItem, doneItem, cancelItem] : @[doneItem, cancelItem];
    toolbar.items = items;

    inputItem = nil;
    doneItem = nil;
    cancelItem = nil;

    CreateToolbarResult ret = {toolbar, items};
    return ret;
}

#endif

- (id)init
{
    NSAssert(s_Keyboard == nil, @"You can have only one instance of iOSScreenKeyboardDelegate");
    self = [super init];
    if (self)
    {
#if PLATFORM_IOS
        m_TextView = [[UITextView alloc] initWithFrame: CGRectMake(0, 840, 480, 30)];
        m_TextView.delegate = self;
        m_TextView.font = [UIFont systemFontOfSize: 18.0];
        m_TextView.hidden = YES;
#endif

        m_TextField = [[UITextField alloc] initWithFrame: CGRectMake(0, 0, 120, 30)];
        m_TextField.delegate = self;
        m_TextField.borderStyle = UITextBorderStyleRoundedRect;
        m_TextField.font = [UIFont systemFontOfSize: 20.0];
        m_TextField.clearButtonMode = UITextFieldViewModeWhileEditing;

#if PLATFORM_IOS
        m_WidthConstraint = [NSLayoutConstraint constraintWithItem: m_TextField attribute: NSLayoutAttributeWidth relatedBy: NSLayoutRelationEqual toItem: nil attribute: NSLayoutAttributeNotAnAttribute multiplier: 1.0 constant: m_TextField.frame.size.width];
        [m_TextField addConstraint: m_WidthConstraint];
#endif
        [m_TextField addTarget: self action: @selector(textFieldDidChange:) forControlEvents: UIControlEventEditingChanged];

        // Workaround missing textFieldDidChangeSelection callback on earlier versions
        if (@available(iOS 13.0, tvOS 13.0, *))
        {
            // Empty on purpose
        }
        else
        {
            [m_TextField addObserver: self forKeyPath: @"selectedTextRange" options: NSKeyValueObservingOptionNew | NSKeyValueObservingOptionOld  context: nil];
        }
#define CREATE_TOOLBAR(t, i, v)                                 \
do {                                                            \
CreateToolbarResult res = [self createToolbarWithView:v];   \
t = res.toolbar;                                            \
i = res.items;                                              \
} while(0)

#if PLATFORM_IOS
        CREATE_TOOLBAR(m_ViewToolbar, m_ViewToolbarItems, nil);
        CREATE_TOOLBAR(m_FieldToolbar, m_FieldToolbarItems, m_TextField);
#endif

#undef CREATE_TOOLBAR

#if PLATFORM_IOS
        [[NSNotificationCenter defaultCenter] addObserver: self selector: @selector(keyboardWillShow:) name: UIKeyboardWillShowNotification object: nil];
        [[NSNotificationCenter defaultCenter] addObserver: self selector: @selector(keyboardDidShow:) name: UIKeyboardDidShowNotification object: nil];
        [[NSNotificationCenter defaultCenter] addObserver: self selector: @selector(keyboardWillHide:) name: UIKeyboardWillHideNotification object: nil];
        [[NSNotificationCenter defaultCenter] addObserver: self selector: @selector(keyboardDidChangeFrame:) name: UIKeyboardDidChangeFrameNotification object: nil];
#endif

        [[NSNotificationCenter defaultCenter] addObserver: self selector: @selector(textInputDone:) name: UITextFieldTextDidEndEditingNotification object: nil];
    }

    return self;
}

- (void)setTextInputTraits:(id<UITextInputTraits>)traits
    withParam:(iOSScreenKeyboardShowParamsNative)param
    withCap:(UITextAutocapitalizationType)capitalization
{
    traits.keyboardType = param.keyboardType;
    traits.autocorrectionType = param.autocorrectionType;
    traits.secureTextEntry = param.secure;
    traits.keyboardAppearance = param.appearance;
    traits.autocapitalizationType = capitalization;
}

// we need to show/hide keyboard to react to orientation too, so extract we extract UI fiddling

- (void)showUI
{
    // if we unhide everything now the input will be shown smaller then needed quickly (and resized later)
    // so unhide only when keyboard is actually shown (we will update it when reacting to ios notifications)

    [NSObject cancelPreviousPerformRequestsWithTarget: self];
    if (!m_InputView.isFirstResponder)
    {
        m_EditView.hidden = YES;

        [UnityGetGLView() addSubview: m_EditView];
        [m_InputView becomeFirstResponder];
    }
}

- (void)hideUI
{
    [NSObject cancelPreviousPerformRequestsWithTarget: self];
    [self performSelector: @selector(hideUIDelayed) withObject: nil afterDelay: 0.05]; // to avoid unnecessary hiding
}

- (void)hideUIDelayed
{
    [m_InputView resignFirstResponder];

    [m_EditView removeFromSuperview];
    m_EditView.hidden = YES;
}

- (void)systemHideKeyboard
{
    // when we are rotating os will bombard us with keyboardWillHide: and keyboardDidChangeFrame:
    // ignore all of them (we do it here only to simplify code: we call systemHideKeyboard only from these notification handlers)
    if (m_Rotating)
        return;

    m_Active = m_EditView.isFirstResponder;
    m_EditView.hidden = YES;

    m_Area = CGRectMake(0, 0, 0, 0);
}

- (void)updateInputHidden
{
    if (m_ShouldHideInputChanged)
    {
        [self shouldHideInput: m_ShouldHideInput];
        m_ShouldHideInputChanged = false;
    }

    m_TextField.returnKeyType = m_InputHidden ? UIReturnKeyDone : UIReturnKeyDefault;

    m_EditView.hidden     = m_InputHidden ? YES : NO;
    m_InputView.hidden    = m_InputHidden ? YES : NO;
}

#if PLATFORM_IOS
- (void)positionInput:(CGRect)kbRect x:(float)x y:(float)y
{
    float safeAreaInsetLeft = 0;
    float safeAreaInsetRight = 0;

#if UNITY_HAS_IOSSDK_11_0
    if (@available(iOS 11.0, *))
    {
        safeAreaInsetLeft = [UnityGetGLView() safeAreaInsets].left;
        safeAreaInsetRight = [UnityGetGLView() safeAreaInsets].right;
    }
#endif

    if (m_ShowParams.multiline)
    {
        // use smaller area for iphones and bigger one for ipads
        int height = UnityDeviceDPI() > 300 ? 75 : 100;

        m_EditView.frame  = CGRectMake(safeAreaInsetLeft, y - height, kbRect.size.width - safeAreaInsetLeft - safeAreaInsetRight, height);
    }
    else
    {
        m_EditView.frame  = CGRectMake(0, y - kToolBarHeight, kbRect.size.width, kToolBarHeight);

        // old constraint must be removed, changing value while constraint is active causes conflict when changing m_InputView.frame
        [m_InputView removeConstraint: m_WidthConstraint];

        m_InputView.frame = CGRectMake(m_InputView.frame.origin.x,
            m_InputView.frame.origin.y,
            kbRect.size.width - safeAreaInsetLeft - safeAreaInsetRight - kSystemButtonsSpace,
            m_InputView.frame.size.height);

        // required to avoid auto-resizing on iOS 11 in case if input text is too long
        m_WidthConstraint.constant = m_InputView.frame.size.width;
        [m_InputView addConstraint: m_WidthConstraint];
    }

    m_Area = CGRectMake(x, y, kbRect.size.width, kbRect.size.height);
    [self updateInputHidden];
}

#endif

- (CGRect)queryArea
{
    return m_EditView.hidden ? m_Area : CGRectUnion(m_Area, m_EditView.frame);
}

// TODO
/*
+ (void)StartReorientation
{
    // TODO
    if (s_Keyboard && s_Keyboard.active)
        s_Keyboard->m_Rotating = YES;
}

+ (void)FinishReorientation
{
    // TODO
    if (s_Keyboard)
        s_Keyboard->m_Rotating = NO;
}*/

- (NSString*)getText
{
#if PLATFORM_TVOS
    return [m_TextField text];
#else
    return m_ShowParams.multiline ? [m_TextView text] : [m_TextField text];
#endif
}

- (void)setText:(NSString*)newText
{
    NSString* originalText = self.getText;
    if ([originalText isEqualToString: newText])
        return;
    UIView<UITextInput>* textInput;
#if PLATFORM_IOS
    if (m_ShowParams.multiline)
    {
        m_TextView.text = newText;
        textInput = m_TextView;
    }
    else
#endif
    {
        m_TextField.text = newText;
        textInput = m_TextField;
        
        if (@available(iOS 13.0, tvOS 13.0, *))
        {
            // Empty on purpose
        }
        else
        {
            [self selectionChangeImpl: [iOSScreenKeyboardDelegate getSelectionFromTextInput: textInput]];
        }
    }
    
    // Setting text doesn't trigger callbacks, do it manually
    [self textDidChangeImpl: newText];
}

+ (NSRange)getSelectionFromTextInput:(UIView<UITextInput>*)textInput
{
    UITextPosition* beginning = textInput.beginningOfDocument;

    UITextRange* selectedRange = textInput.selectedTextRange;
    UITextPosition* selectionStart = selectedRange.start;
    UITextPosition* selectionEnd = selectedRange.end;

    const NSInteger location = [textInput offsetFromPosition: beginning toPosition: selectionStart];
    const NSInteger length = [textInput offsetFromPosition: selectionStart toPosition: selectionEnd];

    return NSMakeRange(location, length);
}

- (NSRange)getSelection
{
    // TODO
    //if (_inputHidden && _hiddenSelection.length > 0)
    //   return _hiddenSelection;
    UIView<UITextInput>* textInput;

#if PLATFORM_TVOS
    textInput = m_TextField;
#else
    textInput = m_ShowParams.multiline ? m_TextView : m_TextField;
#endif

    return [iOSScreenKeyboardDelegate getSelectionFromTextInput: textInput];
}

- (void)setSelection:(NSRange)newSelection
{
    if (NSEqualRanges(self.getSelection, newSelection))
        return;
    UIView<UITextInput>* textInput;

#if PLATFORM_TVOS
    textInput = m_TextField;
#else
    textInput = m_ShowParams.multiline ? m_TextView : m_TextField;
#endif

    UITextPosition* begin = [textInput beginningOfDocument];
    UITextPosition* caret = [textInput positionFromPosition: begin offset: newSelection.location];
    UITextPosition* select = [textInput positionFromPosition: caret offset: newSelection.length];
    UITextRange* textRange = [textInput textRangeFromPosition: caret toPosition: select];

    [textInput setSelectedTextRange: textRange];
    //TODO
    //if (_inputHidden)
    //    _hiddenSelection = newSelection;
}

- (void)shouldHideInput:(BOOL)hide
{
    if (hide)
    {
        switch (m_ShowParams.keyboardType)
        {
            case UIKeyboardTypeDefault:                 hide = YES; break;
            case UIKeyboardTypeASCIICapable:            hide = YES; break;
            case UIKeyboardTypeNumbersAndPunctuation:   hide = YES; break;
            case UIKeyboardTypeURL:                     hide = YES; break;
            case UIKeyboardTypeNumberPad:               hide = NO;  break;
            case UIKeyboardTypePhonePad:                hide = NO;  break;
            case UIKeyboardTypeNamePhonePad:            hide = NO;  break;
            case UIKeyboardTypeEmailAddress:            hide = YES; break;
            case UIKeyboardTypeTwitter:                 hide = YES; break;
            case UIKeyboardTypeWebSearch:               hide = YES; break;
            default:                                    hide = NO;  break;
        }
    }

    m_InputHidden = hide;
}

#if FILTER_EMOJIS_IOS_KEYBOARD

static bool StringContainsEmoji(NSString *string);
- (BOOL)textField:(UITextField*)textField shouldChangeCharactersInRange:(NSRange)range replacementString:(NSString*)string_
{
    if (range.length + range.location > textField.text.length)
        return NO;

    return [self currentText: textField.text shouldChangeInRange: range replacementText: string_] && !StringContainsEmoji(string_);
}

- (BOOL)textView:(UITextView*)textView shouldChangeTextInRange:(NSRange)range replacementText:(NSString*)text_
{
    if (range.length + range.location > textView.text.length)
        return NO;

    return [self currentText: textView.text shouldChangeInRange: range replacementText: text_] && !StringContainsEmoji(text_);
}

#else

- (BOOL)textField:(UITextField *)textField shouldChangeCharactersInRange:(NSRange)range replacementString:(NSString*)string_
{
    if (range.length + range.location > textField.text.length)
        return NO;

    return [self currentText: textField.text shouldChangeInRange: range replacementText: string_];
}

- (BOOL)textView:(UITextView *)textView shouldChangeTextInRange:(NSRange)range replacementText:(NSString*)text_
{
    if (range.length + range.location > textView.text.length)
        return NO;

    return [self currentText: textView.text shouldChangeInRange: range replacementText: text_];
}

#endif // FILTER_EMOJIS_IOS_KEYBOARD

- (BOOL)currentText:(NSString*)currentText shouldChangeInRange:(NSRange)range  replacementText:(NSString*)text_
{
    // TODO
    return YES;
    /*
    NSUInteger newLength = currentText.length + (text_.length - range.length);
    if (newLength > _characterLimit && _characterLimit != 0 && newLength >= currentText.length)
    {
        NSString* newReplacementText = @"";
        if ((currentText.length - range.length) < _characterLimit)
            newReplacementText = [text_ substringWithRange: NSMakeRange(0, _characterLimit - (currentText.length - range.length))];

        NSString* newText = [currentText stringByReplacingCharactersInRange: range withString: newReplacementText];

#if PLATFORM_IOS
        if (m_ShowParams.multiline)
            [m_TextView setText: newText];
        else
            [m_TextField setText: newText];
#else
        [m_TextField setText: newText];
#endif

        return NO;
    }
    else
    {
        return YES;
    }
     */
}

@end
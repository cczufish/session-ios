
@objc(LKProfilePictureView)
public final class ProfilePictureView : UIView {
    private var imageViewWidthConstraint: NSLayoutConstraint!
    private var imageViewHeightConstraint: NSLayoutConstraint!
    @objc public var size: CGFloat = 0 // Not an implicitly unwrapped optional due to Obj-C limitations
    @objc public var isRSSFeed = false
    @objc public var hexEncodedPublicKey: String!
    @objc public var additionalHexEncodedPublicKey: String?
    
    // MARK: Components
    private lazy var imageView = getImageView()
    private lazy var additionalImageView = getImageView()
    
    // MARK: Lifecycle
    public override init(frame: CGRect) {
        super.init(frame: frame)
        setUpViewHierarchy()
    }
    
    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUpViewHierarchy()
    }
    
    private func setUpViewHierarchy() {
        // Set up image view
        addSubview(imageView)
        imageView.pin(.leading, to: .leading, of: self)
        imageView.pin(.top, to: .top, of: self)
        // Set up additional image view
        addSubview(additionalImageView)
        additionalImageView.pin(.trailing, to: .trailing, of: self)
        additionalImageView.pin(.bottom, to: .bottom, of: self)
        let additionalImageViewSize = CGFloat(35) // Values.smallProfilePictureSize
        additionalImageView.set(.width, to: additionalImageViewSize)
        additionalImageView.set(.height, to: additionalImageViewSize)
        additionalImageView.layer.cornerRadius = additionalImageViewSize / 2
    }
    
    // MARK: Updating
    @objc public func update() {
        if let imageViewWidthConstraint = imageViewWidthConstraint, let imageViewHeightConstraint = imageViewHeightConstraint {
            imageView.removeConstraint(imageViewWidthConstraint)
            imageView.removeConstraint(imageViewHeightConstraint)
        }
        func getProfilePicture(of size: CGFloat, for hexEncodedPublicKey: String) -> UIImage? {
            guard !hexEncodedPublicKey.isEmpty else { return nil }
            return OWSProfileManager.shared().profileAvatar(forRecipientId: hexEncodedPublicKey) ?? Identicon.generateIcon(string: hexEncodedPublicKey, size: size)
        }
        let size: CGFloat
        if let additionalHexEncodedPublicKey = additionalHexEncodedPublicKey, !isRSSFeed {
            size = 35 // Values.smallProfilePictureSize
            imageViewWidthConstraint = imageView.set(.width, to: size)
            imageViewHeightConstraint = imageView.set(.height, to: size)
            additionalImageView.isHidden = false
            additionalImageView.image = getProfilePicture(of: size, for: additionalHexEncodedPublicKey)
        } else {
            size = self.size
            imageViewWidthConstraint = imageView.pin(.trailing, to: .trailing, of: self)
            imageViewHeightConstraint = imageView.pin(.bottom, to: .bottom, of: self)
            additionalImageView.isHidden = true
            additionalImageView.image = nil
        }
        imageView.image = isRSSFeed ? nil : getProfilePicture(of: size, for: hexEncodedPublicKey)
        imageView.backgroundColor = isRSSFeed ? UIColor(rgbHex: 0x353535) : UIColor(rgbHex: 0xD8D8D8) // UIColor(rgbHex: 0xD8D8D8) = Colors.unimportant
        imageView.layer.cornerRadius = size / 2
        imageView.contentMode = isRSSFeed ? .center : .scaleAspectFit
        if isRSSFeed {
            imageView.image = #imageLiteral(resourceName: "SessionWhite").resizedImage(to: CGSize(width: (303*24)/337, height: 24))
        }
    }
    
    // MARK: Convenience
    private func getImageView() -> UIImageView {
        let result = UIImageView()
        result.layer.masksToBounds = true
        result.backgroundColor = UIColor(rgbHex: 0xD8D8D8) // Colors.unimportant
        result.layer.borderColor = UIColor(rgbHex: 0x979797).cgColor // Colors.border
        result.layer.borderWidth = 1 // Values.borderThickness
        result.contentMode = .scaleAspectFit
        return result
    }
}

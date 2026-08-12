import Photos
import UIKit

/// An in-app first stop for choosing a reference. It keeps the shooting studio
/// visible and only hands off to PHPicker when the photographer asks for all photos.
@MainActor
final class ReferencePhotoDrawerViewController: UIViewController {
    var onSelectAsset: ((PHAsset) -> Void)?
    var onOpenAllPhotos: (() -> Void)?

    private let imageManager = PHCachingImageManager()
    private var assets: PHFetchResult<PHAsset>?
    private var didRequestAuthorization = false

    private let closeButton = PhotoDrawerBackButton()
    private let collectionView: UICollectionView
    private let loadingIndicator = UIActivityIndicatorView(style: .medium)
    private let emptyState = UIView()
    private let emptySymbol = UIImageView()
    private let emptyLabel = UILabel()
    private let allPhotosButton = PhotoLibraryMaterialButton()

    init() {
        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 2
        layout.minimumLineSpacing = 2
        layout.sectionInset = UIEdgeInsets(top: 0, left: 14, bottom: 90, right: 14)
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureAppearance()
        configureCloseButton()
        configureCollection()
        configureEmptyState()
        configureAllPhotosButton()
        beginLoadingPhotos()
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    private func configureAppearance() {
        view.backgroundColor = StudioUIKitTheme.ink
        view.layer.cornerCurve = .continuous
    }

    private func configureCloseButton() {
        closeButton.addTarget(self, action: #selector(close), for: .touchUpInside)

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(closeButton)

        NSLayoutConstraint.activate([
            closeButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            closeButton.widthAnchor.constraint(equalToConstant: 54),
            closeButton.heightAnchor.constraint(equalToConstant: 54)
        ])
    }

    private func configureCollection() {
        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceVertical = true
        collectionView.showsVerticalScrollIndicator = false
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(RecentPhotoCell.self, forCellWithReuseIdentifier: RecentPhotoCell.reuseIdentifier)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)

        NSLayoutConstraint.activate([
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: view.topAnchor, constant: 14),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func configureEmptyState() {
        emptyState.isHidden = true
        emptyState.isUserInteractionEnabled = false
        emptyState.translatesAutoresizingMaskIntoConstraints = false

        emptySymbol.tintColor = StudioUIKitTheme.mutedPaper
        emptySymbol.contentMode = .scaleAspectFit
        emptySymbol.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.textColor = StudioUIKitTheme.mutedPaper
        emptyLabel.font = StudioUIKitTheme.roundedFont(size: 14, weight: .medium, textStyle: .body)
        emptyLabel.textAlignment = .center
        emptyLabel.numberOfLines = 2
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        emptyState.addSubview(emptySymbol)
        emptyState.addSubview(emptyLabel)
        view.addSubview(emptyState)
        loadingIndicator.color = StudioUIKitTheme.paper
        loadingIndicator.hidesWhenStopped = true
        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(loadingIndicator)

        NSLayoutConstraint.activate([
            emptyState.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 30),
            emptyState.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -30),
            emptyState.centerYAnchor.constraint(equalTo: collectionView.centerYAnchor, constant: -12),

            emptySymbol.centerXAnchor.constraint(equalTo: emptyState.centerXAnchor),
            emptySymbol.topAnchor.constraint(equalTo: emptyState.topAnchor),
            emptySymbol.widthAnchor.constraint(equalToConstant: 28),
            emptySymbol.heightAnchor.constraint(equalToConstant: 28),

            emptyLabel.leadingAnchor.constraint(equalTo: emptyState.leadingAnchor),
            emptyLabel.trailingAnchor.constraint(equalTo: emptyState.trailingAnchor),
            emptyLabel.topAnchor.constraint(equalTo: emptySymbol.bottomAnchor, constant: 10),
            emptyLabel.bottomAnchor.constraint(equalTo: emptyState.bottomAnchor),

            loadingIndicator.centerXAnchor.constraint(equalTo: collectionView.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: collectionView.centerYAnchor, constant: -12)
        ])
    }

    private func configureAllPhotosButton() {
        allPhotosButton.addTarget(self, action: #selector(openAllPhotos), for: .touchUpInside)
        allPhotosButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(allPhotosButton)

        NSLayoutConstraint.activate([
            allPhotosButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
            allPhotosButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            allPhotosButton.heightAnchor.constraint(equalToConstant: 54),
            closeButton.centerYAnchor.constraint(equalTo: allPhotosButton.centerYAnchor)
        ])
        view.bringSubviewToFront(closeButton)
    }

    private func beginLoadingPhotos() {
        loadingIndicator.startAnimating()
        emptyState.isHidden = true
        collectionView.isHidden = true

        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined, !didRequestAuthorization {
            didRequestAuthorization = true
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] newStatus in
                Task { @MainActor [weak self] in
                    self?.handleAuthorization(newStatus)
                }
            }
        } else {
            handleAuthorization(status)
        }
    }

    private func handleAuthorization(_ status: PHAuthorizationStatus) {
        switch status {
        case .authorized, .limited:
            fetchAssets()
        case .denied, .restricted:
            showEmptyState(
                symbol: "photo.on.rectangle.angled",
                text: "可通过“全部照片”选择参考图"
            )
        case .notDetermined:
            break
        @unknown default:
            showEmptyState(
                symbol: "photo.on.rectangle.angled",
                text: "可通过“全部照片”选择参考图"
            )
        }
    }

    private func fetchAssets() {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        assets = PHAsset.fetchAssets(with: .image, options: options)
        loadingIndicator.stopAnimating()

        if assets?.count == 0 {
            showEmptyState(symbol: "photo", text: "照片库里还没有可用照片")
        } else {
            emptyState.isHidden = true
            collectionView.isHidden = false
            collectionView.reloadData()
        }
    }

    private func showEmptyState(symbol: String, text: String) {
        loadingIndicator.stopAnimating()
        collectionView.isHidden = true
        emptySymbol.image = UIImage(systemName: symbol)
        emptyLabel.text = text
        emptyState.isHidden = false
    }

    @objc private func close() {
        dismiss(animated: true)
    }

    @objc private func openAllPhotos() {
        onOpenAllPhotos?()
    }
}

extension ReferencePhotoDrawerViewController: UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        assets?.count ?? 0
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        guard let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: RecentPhotoCell.reuseIdentifier,
            for: indexPath
        ) as? RecentPhotoCell,
        let asset = assets?.object(at: indexPath.item) else {
            return UICollectionViewCell()
        }

        let scale = view.window?.screen.scale ?? traitCollection.displayScale
        let side = (collectionView.bounds.width - 32) / 3
        let targetSize = CGSize(width: side * scale, height: side * scale)
        cell.configure(asset: asset, imageManager: imageManager, targetSize: targetSize)
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let asset = assets?.object(at: indexPath.item) else { return }
        StudioHaptics.alignment(enabled: true)
        onSelectAsset?(asset)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        let width = collectionView.bounds.width - 28 - 4
        let side = floor(width / 3)
        return CGSize(width: side, height: side)
    }
}

private final class RecentPhotoCell: UICollectionViewCell {
    static let reuseIdentifier = "recent-photo"

    private let imageView = UIImageView()
    private let liveBadge = UIImageView(image: UIImage(systemName: "livephoto"))
    private weak var imageManager: PHImageManager?
    private var requestID = PHInvalidImageRequestID
    private var representedAssetIdentifier: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = StudioUIKitTheme.liftedInk
        clipsToBounds = true
        layer.cornerRadius = 3
        layer.cornerCurve = .continuous

        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        contentView.addSubview(imageView)
        imageView.pinEdges(to: contentView)
        isAccessibilityElement = true

        liveBadge.tintColor = .white
        liveBadge.contentMode = .scaleAspectFit
        liveBadge.layer.shadowColor = UIColor.black.cgColor
        liveBadge.layer.shadowOpacity = 0.65
        liveBadge.layer.shadowRadius = 2
        liveBadge.layer.shadowOffset = .zero
        liveBadge.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(liveBadge)

        NSLayoutConstraint.activate([
            liveBadge.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -7),
            liveBadge.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 7),
            liveBadge.widthAnchor.constraint(equalToConstant: 17),
            liveBadge.heightAnchor.constraint(equalToConstant: 17)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        if requestID != PHInvalidImageRequestID {
            imageManager?.cancelImageRequest(requestID)
        }
        imageManager = nil
        requestID = PHInvalidImageRequestID
        representedAssetIdentifier = nil
        imageView.image = nil
        liveBadge.isHidden = true
    }

    func configure(asset: PHAsset, imageManager: PHImageManager, targetSize: CGSize) {
        self.imageManager = imageManager
        representedAssetIdentifier = asset.localIdentifier
        liveBadge.isHidden = !asset.mediaSubtypes.contains(.photoLive)
        accessibilityLabel = asset.mediaSubtypes.contains(.photoLive) ? "实况照片" : "照片"
        accessibilityHint = "用作参考图"

        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        requestID = imageManager.requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: options
        ) { [weak self] image, _ in
            guard let self, representedAssetIdentifier == asset.localIdentifier else { return }
            imageView.image = image
        }
    }

    override var isHighlighted: Bool {
        didSet {
            UIView.animate(withDuration: 0.12) {
                self.transform = self.isHighlighted
                    ? CGAffineTransform(scaleX: 0.96, y: 0.96)
                    : .identity
                self.alpha = self.isHighlighted ? 0.78 : 1
            }
        }
    }
}

private final class PhotoDrawerBackButton: UIButton {
    private let fallbackMaterialView: UIVisualEffectView?

    init() {
        if #available(iOS 26.0, *) {
            fallbackMaterialView = nil
        } else {
            fallbackMaterialView = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterialDark))
        }
        super.init(frame: .zero)

        var configuration: UIButton.Configuration
        if #available(iOS 26.0, *) {
            configuration = .glass()
        } else {
            configuration = .plain()
        }
        configuration.image = UIImage(systemName: "chevron.left")
        configuration.cornerStyle = .capsule
        configuration.baseForegroundColor = .white
        configuration.contentInsets = .zero
        self.configuration = configuration
        accessibilityLabel = "返回"

        installFallbackMaterialIfNeeded()
        layer.cornerRadius = 27
        layer.cornerCurve = .continuous
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.24
        layer.shadowRadius = 12
        layer.shadowOffset = CGSize(width: 0, height: 6)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        fallbackMaterialView?.frame = bounds
        fallbackMaterialView?.layer.cornerRadius = bounds.height / 2
    }

    private func installFallbackMaterialIfNeeded() {
        guard let fallbackMaterialView else { return }
        fallbackMaterialView.isUserInteractionEnabled = false
        fallbackMaterialView.clipsToBounds = true
        insertSubview(fallbackMaterialView, at: 0)
    }
}

private final class PhotoLibraryMaterialButton: UIButton {
    private let fallbackMaterialView: UIVisualEffectView?

    init() {
        if #available(iOS 26.0, *) {
            fallbackMaterialView = nil
        } else {
            fallbackMaterialView = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterialDark))
        }
        super.init(frame: .zero)

        var configuration: UIButton.Configuration
        if #available(iOS 26.0, *) {
            configuration = .glass()
        } else {
            configuration = .plain()
        }
        configuration.title = "全部照片"
        configuration.cornerStyle = .capsule
        configuration.image = UIImage(systemName: "chevron.right")
        configuration.imagePlacement = .trailing
        configuration.imagePadding = 9
        configuration.baseForegroundColor = .white
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 22, bottom: 0, trailing: 18)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var result = incoming
            result.font = StudioUIKitTheme.roundedFont(size: 16, weight: .semibold, textStyle: .body)
            return result
        }
        self.configuration = configuration
        accessibilityHint = "打开系统照片选择器"

        installFallbackMaterialIfNeeded()
        layer.cornerRadius = 27
        layer.cornerCurve = .continuous
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.24
        layer.shadowRadius = 14
        layer.shadowOffset = CGSize(width: 0, height: 7)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        fallbackMaterialView?.frame = bounds
        fallbackMaterialView?.layer.cornerRadius = bounds.height / 2
    }

    private func installFallbackMaterialIfNeeded() {
        guard let fallbackMaterialView else { return }
        fallbackMaterialView.isUserInteractionEnabled = false
        fallbackMaterialView.clipsToBounds = true
        insertSubview(fallbackMaterialView, at: 0)
    }
}

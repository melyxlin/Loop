//
//  BolusProgressTableViewCell.swift
//  LoopUI
//
//  Created by Pete Schwamb on 3/11/19.
//  Copyright © 2019 LoopKit Authors. All rights reserved.
//

import Foundation
import LoopKit
import LoopUI
import LoopAlgorithm
//import MKRingProgressView


public class BolusProgressTableViewCell: UITableViewCell {
    
    public enum Configuration {
        case starting
        case bolusing(delivered: Double?, ofTotalVolume: Double)
        case canceling
        case canceled(delivered: Double, ofTotalVolume: Double)
    }
    
    private let paddedView = UIView()

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.text = NSLocalizedString(
            "Bolus in Progress",
            comment: "Title shown while a bolus is being delivered"
        )
        label.font = .preferredFont(forTextStyle: .headline)
        label.adjustsFontForContentSizeCategory = true
        return label
    }()

    private let progressLabel: UILabel = {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = UIColor.label.withAlphaComponent(0.75)
        return label
    }()

    private let progressView: UIProgressView = {
        let view = UIProgressView(progressViewStyle: .default)
        view.progress = 0
        return view
    }()

    private let percentLabel: UILabel = {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .caption1)
        label.textColor = .secondaryLabel
        label.textAlignment = .right
        return label
    }()

    let activityIndicator = UIActivityIndicatorView(style: .medium)

    private let cancelImageView: UIImageView = {
        let view = UIImageView(
            image: UIImage(systemName: "xmark.circle.fill")
        )
        view.contentMode = .scaleAspectFit
        view.tintColor = .secondaryLabel
        view.setContentHuggingPriority(.required, for: .horizontal)
        return view
    }()
    
    @IBOutlet weak var tapToStopLabel: UILabel! {
        didSet {
            tapToStopLabel.text = NSLocalizedString("Tap to Stop", comment: "Message presented in the status row instructing the user to tap this row to stop a bolus")
        }
    }

    @IBOutlet weak var stopSquare: UIView! {
        didSet {
            stopSquare.layer.cornerRadius = 2
        }
    }

    public var configuration: Configuration? {
        didSet {
            updateProgress()
        }
    }

    lazy var insulinFormatter: QuantityFormatter = {
        let formatter = QuantityFormatter(for: .internationalUnit)
        formatter.numberFormatter.minimumFractionDigits = 2
        return formatter
    }()

    override public func awakeFromNib() {
        super.awakeFromNib()

        selectionStyle = .none
        backgroundColor = .secondarySystemBackground
        contentView.backgroundColor = .secondarySystemBackground

        paddedView.translatesAutoresizingMaskIntoConstraints = false
        paddedView.layer.cornerRadius = 14
        paddedView.layer.masksToBounds = true

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        progressLabel.translatesAutoresizingMaskIntoConstraints = false
        progressView.translatesAutoresizingMaskIntoConstraints = false
        percentLabel.translatesAutoresizingMaskIntoConstraints = false
        activityIndicator.translatesAutoresizingMaskIntoConstraints = false
        cancelImageView.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(paddedView)

        paddedView.addSubview(titleLabel)
        paddedView.addSubview(progressLabel)
        paddedView.addSubview(progressView)
        paddedView.addSubview(percentLabel)
        paddedView.addSubview(activityIndicator)
        paddedView.addSubview(cancelImageView)

        NSLayoutConstraint.activate([
            paddedView.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor,
                constant: 8
            ),
            paddedView.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor,
                constant: -8
            ),
            paddedView.topAnchor.constraint(
                equalTo: contentView.topAnchor
            ),
            paddedView.bottomAnchor.constraint(
                equalTo: contentView.bottomAnchor,
                constant: -8
            ),

            titleLabel.leadingAnchor.constraint(
                equalTo: paddedView.leadingAnchor,
                constant: 16
            ),
            titleLabel.topAnchor.constraint(
                equalTo: paddedView.topAnchor,
                constant: 12
            ),

            cancelImageView.trailingAnchor.constraint(
                equalTo: paddedView.trailingAnchor,
                constant: -14
            ),
            cancelImageView.centerYAnchor.constraint(
                equalTo: titleLabel.centerYAnchor
            ),
            cancelImageView.widthAnchor.constraint(equalToConstant: 22),
            cancelImageView.heightAnchor.constraint(equalToConstant: 22),

            titleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: cancelImageView.leadingAnchor,
                constant: -8
            ),

            progressLabel.leadingAnchor.constraint(
                equalTo: titleLabel.leadingAnchor
            ),
            progressLabel.trailingAnchor.constraint(
                equalTo: paddedView.trailingAnchor,
                constant: -16
            ),
            progressLabel.topAnchor.constraint(
                equalTo: titleLabel.bottomAnchor,
                constant: 3
            ),

            progressView.leadingAnchor.constraint(
                equalTo: titleLabel.leadingAnchor
            ),
            progressView.topAnchor.constraint(
                equalTo: progressLabel.bottomAnchor,
                constant: 9
            ),

            percentLabel.leadingAnchor.constraint(
                equalTo: progressView.trailingAnchor,
                constant: 10
            ),
            percentLabel.trailingAnchor.constraint(
                equalTo: paddedView.trailingAnchor,
                constant: -16
            ),
            percentLabel.centerYAnchor.constraint(
                equalTo: progressView.centerYAnchor
            ),
            percentLabel.widthAnchor.constraint(
                greaterThanOrEqualToConstant: 34
            ),

            progressView.bottomAnchor.constraint(
                equalTo: paddedView.bottomAnchor,
                constant: -14
            ),

            activityIndicator.centerXAnchor.constraint(
                equalTo: paddedView.centerXAnchor
            ),
            activityIndicator.centerYAnchor.constraint(
                equalTo: paddedView.centerYAnchor
            )
        ])

        updateColors()
        updateProgress()
    }

    private func updateColors() {
        paddedView.backgroundColor = tintColor.withAlphaComponent(0.10)

        progressView.progressTintColor = tintColor
        progressView.trackTintColor = tintColor.withAlphaComponent(0.18)

        cancelImageView.tintColor = tintColor
    }
    private func updateProgress() {
        guard let configuration else {
            titleLabel.isHidden = true
            progressLabel.isHidden = true
            progressView.isHidden = true
            percentLabel.isHidden = true
            cancelImageView.isHidden = true
            activityIndicator.isHidden = true
            return
        }

        titleLabel.isHidden = false

        switch configuration {

        case .starting:
            titleLabel.text = NSLocalizedString(
                "Starting Bolus",
                comment: "Title shown while a bolus is being started"
            )

            progressLabel.isHidden = true
            progressView.isHidden = true
            percentLabel.isHidden = true
            cancelImageView.isHidden = true

            activityIndicator.isHidden = false
            activityIndicator.startAnimating()

            titleLabel.accessibilityIdentifier = "text_BolusStarting"

        case let .bolusing(delivered, totalVolume):
            titleLabel.text = NSLocalizedString(
                "Bolus in Progress",
                comment: "Title shown while a bolus is being delivered"
            )

            activityIndicator.stopAnimating()
            activityIndicator.isHidden = true

            progressLabel.isHidden = false
            progressView.isHidden = false
            percentLabel.isHidden = false
            cancelImageView.isHidden = false

            let totalUnitsQuantity = LoopQuantity(
                unit: .internationalUnit,
                doubleValue: totalVolume
            )

            let totalUnitsString =
                insulinFormatter.string(from: totalUnitsQuantity) ?? ""

            if let delivered {
                let deliveredUnitsQuantity = LoopQuantity(
                    unit: .internationalUnit,
                    doubleValue: delivered
                )

                let deliveredUnitsString =
                    insulinFormatter.string(
                        from: deliveredUnitsQuantity,
                        includeUnit: false
                    ) ?? ""

                progressLabel.text = String(
                    format: NSLocalizedString(
                        "%1$@ of %2$@ delivered",
                        comment: "Bolus progress showing delivered and total insulin"
                    ),
                    deliveredUnitsString,
                    totalUnitsString
                )

                let progress: Double

                if totalVolume > 0 {
                    progress = min(max(delivered / totalVolume, 0), 1)
                } else {
                    progress = 0
                }

                progressView.setProgress(
                    Float(progress),
                    animated: true
                )

                percentLabel.text = String(
                    format: "%.0f%%",
                    progress * 100
                )
            } else {
                progressLabel.text = String(
                    format: NSLocalizedString(
                        "Delivering %@",
                        comment: "Bolus in progress showing total insulin"
                    ),
                    totalUnitsString
                )

                progressView.setProgress(0, animated: false)
                percentLabel.text = "0%"
            }

            progressLabel.accessibilityIdentifier = "text_BolusingProgress"
            cancelImageView.accessibilityIdentifier = "button_StopBolus"

        case .canceling:
            titleLabel.text = NSLocalizedString(
                "Stopping Bolus",
                comment: "Title shown while a bolus is being canceled"
            )

            progressLabel.isHidden = true
            progressView.isHidden = true
            percentLabel.isHidden = true
            cancelImageView.isHidden = true

            activityIndicator.isHidden = false
            activityIndicator.startAnimating()

            titleLabel.accessibilityIdentifier = "text_BolusCanceling"

        case let .canceled(delivered, totalVolume):
            titleLabel.text = NSLocalizedString(
                "Bolus Stopped",
                comment: "Title shown after a bolus has been canceled"
            )

            activityIndicator.stopAnimating()
            activityIndicator.isHidden = true
            cancelImageView.isHidden = true
            progressView.isHidden = true
            percentLabel.isHidden = true
            progressLabel.isHidden = false

            let totalUnitsQuantity = LoopQuantity(
                unit: .internationalUnit,
                doubleValue: totalVolume
            )

            let totalUnitsString =
                insulinFormatter.string(from: totalUnitsQuantity) ?? ""

            let deliveredUnitsQuantity = LoopQuantity(
                unit: .internationalUnit,
                doubleValue: delivered
            )

            let deliveredUnitsString =
                insulinFormatter.string(
                    from: deliveredUnitsQuantity,
                    includeUnit: false
                ) ?? ""

            progressLabel.text = String(
                format: NSLocalizedString(
                    "%1$@ of %2$@ delivered",
                    comment: "Canceled bolus showing delivered and total insulin"
                ),
                deliveredUnitsString,
                totalUnitsString
            )

            progressLabel.accessibilityIdentifier = "text_BolusCanceled"
        }
    }

    override public func prepareForReuse() {
        super.prepareForReuse()

        configuration = nil

        progressView.setProgress(0, animated: false)
        percentLabel.text = nil
        progressLabel.text = nil
        titleLabel.text = nil

        activityIndicator.stopAnimating()
    }
}

extension BolusProgressTableViewCell: NibLoadable { }

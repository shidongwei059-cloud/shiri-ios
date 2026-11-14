import SwiftUI
import UIKit

/// Three reusable pages keep native finger tracking and paging available on iOS 16+.
struct DateStripPager: UIViewControllerRepresentable {
    @Environment(\.dynamicTypeSize) private var dynamicType
    @Environment(\.colorScheme) private var colorScheme
    var date: Date
    var calendar: Calendar
    var onSelect: (Date) -> Void

    func makeUIViewController(context: Context) -> DateStripController { DateStripController() }

    func updateUIViewController(_ controller: DateStripController, context: Context) {
        controller.update(DateStripConfiguration(date: date, calendar: calendar,
            daysPerPage: dynamicType.isAccessibilitySize ? 3 : 7,
            dynamicType: dynamicType, colorScheme: colorScheme, onSelect: onSelect))
    }
}

private struct DateStripConfiguration {
    var date: Date
    var calendar: Calendar
    var daysPerPage: Int
    var dynamicType: DynamicTypeSize
    var colorScheme: ColorScheme
    var onSelect: (Date) -> Void

    func days(onPage offset: Int) -> [Date] {
        let first: Date
        if daysPerPage == 7 {
            first = calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
        } else {
            first = calendar.date(byAdding: .day, value: -(daysPerPage / 2), to: calendar.startOfDay(for: date)) ?? date
        }
        return (0..<daysPerPage).compactMap { calendar.date(byAdding: .day, value: offset * daysPerPage + $0, to: first) }
    }
}

final class DateStripController: UIViewController, UIScrollViewDelegate {
    private let scrollView = UIScrollView()
    private var pages: [UIHostingController<DateStripPage>] = []
    private var configuration: DateStripConfiguration?
    private var pendingConfiguration: DateStripConfiguration?
    private var layoutSize = CGSize.zero

    override func loadView() {
        view = UIView()
        view.backgroundColor = .clear
        scrollView.backgroundColor = .clear
        scrollView.isPagingEnabled = true
        scrollView.isDirectionalLockEnabled = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.accessibilityIdentifier = "todayWeekStrip"
        scrollView.delegate = self
        view.addSubview(scrollView)
    }

    fileprivate func update(_ value: DateStripConfiguration) {
        loadViewIfNeeded()
        // SwiftUI can refresh the cards during a drag; keep the native scroll position intact.
        guard !scrollView.isDragging, !scrollView.isDecelerating else {
            pendingConfiguration = value
            return
        }
        configuration = value
        renderPages()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        scrollView.frame = view.bounds
        guard layoutSize != view.bounds.size else { return }
        layoutSize = view.bounds.size
        layoutPages()
        centerPage()
    }

    private func renderPages() {
        guard let configuration else { return }
        for offset in -1...1 {
            let root = DateStripPage(days: configuration.days(onPage: offset), configuration: configuration)
            let index = offset + 1
            if pages.indices.contains(index) { pages[index].rootView = root }
            else {
                let host = UIHostingController(rootView: root)
                host.view.backgroundColor = .clear
                addChild(host); scrollView.addSubview(host.view); host.didMove(toParent: self)
                pages.append(host)
            }
            pages[index].view.accessibilityElementsHidden = offset != 0
        }
        layoutPages()
        centerPage()
    }

    private func layoutPages() {
        let size = scrollView.bounds.size
        scrollView.contentSize = CGSize(width: size.width * 3, height: size.height)
        for (index, page) in pages.enumerated() {
            page.view.frame = CGRect(x: CGFloat(index) * size.width, y: 0, width: size.width, height: size.height)
        }
    }

    private func centerPage() {
        scrollView.setContentOffset(CGPoint(x: scrollView.bounds.width, y: 0), animated: false)
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { finishPaging() }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { finishPaging() }
    }
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { finishPaging() }

    private func finishPaging() {
        guard var value = configuration, scrollView.bounds.width > 0 else { return }
        if let pending = pendingConfiguration {
            pendingConfiguration = nil
            // A calendar selection or a return-to-today action takes precedence over an older drag.
            if !pending.calendar.isDate(pending.date, inSameDayAs: value.date) {
                update(pending)
                return
            }
            value = pending
        }
        let offset = min(1, max(-1, Int((scrollView.contentOffset.x / scrollView.bounds.width).rounded()) - 1))
        guard offset != 0, let next = value.calendar.date(byAdding: .day, value: offset * value.daysPerPage, to: value.date) else {
            update(value)
            return
        }
        value.date = next
        configuration = value
        renderPages()
        value.onSelect(next)
    }
}

private struct DateStripPage: View {
    let days: [Date]
    let configuration: DateStripConfiguration
    var body: some View {
        HStack(spacing: 0) {
            ForEach(days, id: \.self) { day in
                let selected = configuration.calendar.isDate(day, inSameDayAs: configuration.date)
                Button { configuration.onSelect(day) } label: {
                    VStack(spacing: 3) {
                        Text(day.formatted(.dateTime.weekday(.narrow)))
                            .font(.caption).foregroundColor(selected ? Paper.accent : Paper.secondary)
                        Text(String(configuration.calendar.component(.day, from: day)))
                            .font(Paper.text(16)).foregroundColor(selected ? .white : Paper.ink)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(selected ? Paper.accent : .clear, in: RoundedRectangle(cornerRadius: 13))
                    }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(.horizontal, 2).padding(.vertical, 3)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel(day.formatted(.dateTime.month().day().weekday()))
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityIdentifier("day_\(configuration.calendar.component(.day, from: day))")
            }
        }
        .environment(\.dynamicTypeSize, configuration.dynamicType)
        .environment(\.colorScheme, configuration.colorScheme)
        .environment(\.calendar, configuration.calendar)
        .environment(\.timeZone, configuration.calendar.timeZone)
    }
}

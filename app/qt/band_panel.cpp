#include "band_panel.hpp"

#include <QCheckBox>
#include <QHBoxLayout>
#include <QLabel>
#include <QVBoxLayout>

namespace cpn {
namespace {

// The S-57 navigational-purpose usage bands (an IHO concept), in display order
// coarse → fine, with the Go web client's band colours. The panel shows a row only
// for ranks actually present in the loaded charts.
struct BandDef {
    int rank;
    const char *label;
    const char *color;
};
const BandDef kBands[] = {
    {5, "Overview", "#7e57c2"}, {4, "General", "#5c6bc0"}, {3, "Coastal", "#26a69a"},
    {2, "Approach", "#9ccc65"}, {1, "Harbor", "#ffa726"}, {0, "Berthing", "#ef5350"},
};

} // namespace

BandPanel::BandPanel(quint32 presentBands, QWidget *parent) : QWidget(parent) {
    auto *col = new QVBoxLayout(this);
    col->setContentsMargins(12, 10, 12, 12);
    col->setSpacing(8);

    for (const auto &b : kBands) {
        if (!(presentBands & (1u << b.rank))) continue; // only bands present in the data

        auto *row = new QWidget;
        auto *h = new QHBoxLayout(row);
        h->setContentsMargins(0, 0, 0, 0);
        h->setSpacing(8);
        auto *dot = new QLabel;
        dot->setFixedSize(12, 12);
        dot->setStyleSheet(QStringLiteral("background: %1; border-radius: 6px;").arg(QString::fromUtf8(b.color)));
        auto *cb = new QCheckBox(QString::fromUtf8(b.label));
        cb->setChecked(true);
        h->addWidget(dot);
        h->addWidget(cb);
        h->addStretch(1);
        col->addWidget(row);

        boxes_.emplace_back(b.rank, cb);
        enabled_.push_back(b.rank);
        connect(cb, &QCheckBox::toggled, this, [this](bool) { pull(); });
    }
}

void BandPanel::pull() {
    enabled_.clear();
    for (const auto &[rank, cb] : boxes_)
        if (cb->isChecked()) enabled_.push_back(rank);
    emit changed(enabled_);
}

} // namespace cpn

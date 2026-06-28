// BandPanel — the data-driven navigational-band filter column.
//
// One toggle per band ACTUALLY PRESENT in the loaded charts (from
// tile57_source_bands), not a fixed list. Band / chart visibility is a chart-source
// concern, deliberately kept OUT of the cross-platform S-52 MarinerSettings; this
// widget owns the enabled band-rank set and emits it whenever a toggle changes, so
// the viewer can rebuild the style's band filter.
#pragma once

#include <QWidget>

#include <utility>
#include <vector>

class QCheckBox;

namespace cpn {

class BandPanel : public QWidget {
    Q_OBJECT
public:
    // presentBands: bitmask from tile57_source_bands (bit r = band rank r present).
    explicit BandPanel(quint32 presentBands, QWidget *parent = nullptr);

    [[nodiscard]] const std::vector<int> &enabled() const { return enabled_; }
    [[nodiscard]] bool hasBands() const { return !boxes_.empty(); }

signals:
    void changed(const std::vector<int> &enabledBandRanks);

private:
    void pull(); // read the toggles -> enabled_, emit changed()

    std::vector<std::pair<int, QCheckBox *>> boxes_; // (band rank, toggle)
    std::vector<int> enabled_;
};

} // namespace cpn

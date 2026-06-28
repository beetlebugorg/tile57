// MarinerPanel — the S-52 mariner-settings control panel (Qt-side UI). Holds a
// chartstyle::MarinerSettings, exposes the achievable axes as controls, and emits
// changed() whenever the mariner adjusts one so the viewer can restyle live.
//
// Only the axes the current S-57 tiles support are shown (depth contours/shades/
// units, safety depth, data-quality + info-callout toggles, palette). The axes that
// need extra per-feature tags from the tile engine (display category, boundary/
// point style, sector legs, text groups, dates) are added once the engine bakes them.
#pragma once

#include "chartstyle/mariner.hpp"

#include <QWidget>

class QCheckBox;
class QComboBox;
class QDoubleSpinBox;

namespace cpn {

class MarinerPanel : public QWidget {
    Q_OBJECT
public:
    explicit MarinerPanel(const chartstyle::MarinerSettings &initial, QWidget *parent = nullptr);
    [[nodiscard]] const chartstyle::MarinerSettings &settings() const { return s_; }

signals:
    void changed(const chartstyle::MarinerSettings &settings);

private:
    void pull();  // read controls -> s_, then emit changed()

    chartstyle::MarinerSettings s_;

    QComboBox *scheme_ = nullptr;
    QCheckBox *displayBase_ = nullptr;
    QCheckBox *displayStandard_ = nullptr;
    QCheckBox *displayOther_ = nullptr;
    QComboBox *depthUnit_ = nullptr;
    QCheckBox *fourShades_ = nullptr;
    QDoubleSpinBox *shallow_ = nullptr;
    QDoubleSpinBox *safety_ = nullptr;
    QDoubleSpinBox *deep_ = nullptr;
    QDoubleSpinBox *safetyDepth_ = nullptr;
    QComboBox *boundaryStyle_ = nullptr;
    QCheckBox *simplifiedPoints_ = nullptr;
    QCheckBox *textNames_ = nullptr;
    QCheckBox *lightDescriptions_ = nullptr;
    QCheckBox *textOther_ = nullptr;
    QCheckBox *dataQuality_ = nullptr;
    QCheckBox *infoCallouts_ = nullptr;
    QCheckBox *metaBounds_ = nullptr;
    QCheckBox *isoDangersShallow_ = nullptr;
    QCheckBox *dateDependent_ = nullptr;
    QCheckBox *highlightDate_ = nullptr;
};

} // namespace cpn

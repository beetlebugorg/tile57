#include "mariner_panel.hpp"

#include <QCheckBox>
#include <QComboBox>
#include <QDoubleSpinBox>
#include <QFormLayout>
#include <QGroupBox>
#include <QLabel>
#include <QVBoxLayout>

namespace cpn {

namespace {
QDoubleSpinBox *metresBox(double value) {
    auto *b = new QDoubleSpinBox;
    b->setRange(0.0, 200.0);
    b->setDecimals(1);
    b->setSingleStep(1.0);
    b->setSuffix(QStringLiteral(" m"));
    b->setValue(value);
    return b;
}
} // namespace

MarinerPanel::MarinerPanel(const tile57_mariner &initial, QWidget *parent)
    : QWidget(parent), s_(initial) {
    setMinimumWidth(280);

    // Consistent breathing room for every group's form.
    const auto tidyForm = [](QFormLayout *f) {
        f->setContentsMargins(12, 10, 12, 12);
        f->setHorizontalSpacing(12);
        f->setVerticalSpacing(8);
        f->setLabelAlignment(Qt::AlignRight | Qt::AlignVCenter);
        f->setFieldGrowthPolicy(QFormLayout::ExpandingFieldsGrow);
    };

    auto *root = new QVBoxLayout(this);
    root->setContentsMargins(12, 12, 12, 12);
    root->setSpacing(14);

    // -- Palette --
    auto *palBox = new QGroupBox(QStringLiteral("Palette"));
    auto *palForm = new QFormLayout(palBox);
    tidyForm(palForm);
    scheme_ = new QComboBox;
    scheme_->addItems({QStringLiteral("Day"), QStringLiteral("Dusk"), QStringLiteral("Night")});
    scheme_->setCurrentIndex(static_cast<int>(s_.scheme));
    palForm->addRow(QStringLiteral("Colour scheme"), scheme_);
    root->addWidget(palBox);

    // -- Display category (S-52 §10.3.4, multi-select) --
    auto *catBox = new QGroupBox(QStringLiteral("Display category"));
    auto *catCol = new QVBoxLayout(catBox);
    catCol->setContentsMargins(12, 10, 12, 12);
    catCol->setSpacing(8);
    displayBase_ = new QCheckBox(QStringLiteral("Base"));
    displayBase_->setChecked(s_.display_base);
    displayBase_->setEnabled(false); // base is always shown
    displayBase_->setToolTip(QStringLiteral("Display Base is always shown"));
    catCol->addWidget(displayBase_);
    displayStandard_ = new QCheckBox(QStringLiteral("Standard"));
    displayStandard_->setChecked(s_.display_standard);
    catCol->addWidget(displayStandard_);
    displayOther_ = new QCheckBox(QStringLiteral("Other"));
    displayOther_->setChecked(s_.display_other);
    catCol->addWidget(displayOther_);
    root->addWidget(catBox);

    // -- Depth --
    auto *depthBox = new QGroupBox(QStringLiteral("Depth"));
    auto *depthForm = new QFormLayout(depthBox);
    tidyForm(depthForm);
    depthUnit_ = new QComboBox;
    depthUnit_->addItems({QStringLiteral("Metres"), QStringLiteral("Feet")});
    depthUnit_->setCurrentIndex(static_cast<int>(s_.depth_unit));
    depthForm->addRow(QStringLiteral("Units"), depthUnit_);
    fourShades_ = new QCheckBox(QStringLiteral("Four depth shades"));
    fourShades_->setChecked(s_.four_shade_water);
    depthForm->addRow(fourShades_);
    shallow_ = metresBox(s_.shallow_contour);
    depthForm->addRow(QStringLiteral("Shallow contour"), shallow_);
    safety_ = metresBox(s_.safety_contour);
    depthForm->addRow(QStringLiteral("Safety contour"), safety_);
    deep_ = metresBox(s_.deep_contour);
    depthForm->addRow(QStringLiteral("Deep contour"), deep_);
    safetyDepth_ = metresBox(s_.safety_depth);
    depthForm->addRow(QStringLiteral("Safety depth"), safetyDepth_);
    root->addWidget(depthBox);

    // -- Symbolization (S-52 §8.6.1 boundaries, §11.2.2 point symbols) --
    auto *symBox = new QGroupBox(QStringLiteral("Symbolization"));
    auto *symForm = new QFormLayout(symBox);
    tidyForm(symForm);
    boundaryStyle_ = new QComboBox;
    boundaryStyle_->addItems({QStringLiteral("Symbolized"), QStringLiteral("Plain")});
    boundaryStyle_->setCurrentIndex(static_cast<int>(s_.boundary_style));
    symForm->addRow(QStringLiteral("Boundaries"), boundaryStyle_);
    simplifiedPoints_ = new QCheckBox(QStringLiteral("Simplified point symbols"));
    simplifiedPoints_->setChecked(s_.simplified_points);
    symForm->addRow(simplifiedPoints_);
    root->addWidget(symBox);

    // -- Text (S-52 §14.5 text groups) --
    auto *textBox = new QGroupBox(QStringLiteral("Text"));
    auto *textCol = new QVBoxLayout(textBox);
    textCol->setContentsMargins(12, 10, 12, 12);
    textCol->setSpacing(8);
    textNames_ = new QCheckBox(QStringLiteral("Names"));
    textNames_->setChecked(s_.text_names);
    textCol->addWidget(textNames_);
    lightDescriptions_ = new QCheckBox(QStringLiteral("Light descriptions"));
    lightDescriptions_->setChecked(s_.show_light_descriptions);
    textCol->addWidget(lightDescriptions_);
    textOther_ = new QCheckBox(QStringLiteral("Other text"));
    textOther_->setChecked(s_.text_other);
    textCol->addWidget(textOther_);
    root->addWidget(textBox);

    // -- Overlays --
    auto *ovBox = new QGroupBox(QStringLiteral("Overlays"));
    auto *ovForm = new QVBoxLayout(ovBox);
    ovForm->setContentsMargins(12, 10, 12, 12);
    ovForm->setSpacing(8);
    dataQuality_ = new QCheckBox(QStringLiteral("Data quality (CATZOC)"));
    dataQuality_->setChecked(s_.data_quality);
    ovForm->addWidget(dataQuality_);
    infoCallouts_ = new QCheckBox(QStringLiteral("Information callouts"));
    infoCallouts_->setChecked(s_.show_inform_callouts);
    ovForm->addWidget(infoCallouts_);
    metaBounds_ = new QCheckBox(QStringLiteral("Cell / coverage boundaries"));
    metaBounds_->setChecked(s_.show_meta_bounds);
    ovForm->addWidget(metaBounds_);
    isoDangersShallow_ = new QCheckBox(QStringLiteral("Isolated dangers in shallow water"));
    isoDangersShallow_->setChecked(s_.show_isolated_dangers_shallow);
    ovForm->addWidget(isoDangersShallow_);
    root->addWidget(ovBox);

    // -- Date-dependent display (S-52 §10.4.1.1) --
    auto *dateBox = new QGroupBox(QStringLiteral("Dates"));
    auto *dateCol = new QVBoxLayout(dateBox);
    dateCol->setContentsMargins(12, 10, 12, 12);
    dateCol->setSpacing(8);
    dateDependent_ = new QCheckBox(QStringLiteral("Hide features out of date"));
    dateDependent_->setChecked(s_.date_dependent);
    dateCol->addWidget(dateDependent_);
    highlightDate_ = new QCheckBox(QStringLiteral("Highlight date-dependent"));
    highlightDate_->setChecked(s_.highlight_date_dependent);
    dateCol->addWidget(highlightDate_);
    root->addWidget(dateBox);

    root->addStretch(1);

    // Every control funnels through pull(): read all controls into s_, emit changed.
    const auto onCombo = [this](int) { pull(); };
    const auto onCheck = [this](bool) { pull(); };
    const auto onSpin = [this](double) { pull(); };
    connect(scheme_, &QComboBox::currentIndexChanged, this, onCombo);
    connect(depthUnit_, &QComboBox::currentIndexChanged, this, onCombo);
    connect(boundaryStyle_, &QComboBox::currentIndexChanged, this, onCombo);
    connect(simplifiedPoints_, &QCheckBox::toggled, this, onCheck);
    connect(displayStandard_, &QCheckBox::toggled, this, onCheck);
    connect(displayOther_, &QCheckBox::toggled, this, onCheck);
    connect(fourShades_, &QCheckBox::toggled, this, onCheck);
    connect(dataQuality_, &QCheckBox::toggled, this, onCheck);
    connect(infoCallouts_, &QCheckBox::toggled, this, onCheck);
    connect(metaBounds_, &QCheckBox::toggled, this, onCheck);
    connect(isoDangersShallow_, &QCheckBox::toggled, this, onCheck);
    connect(dateDependent_, &QCheckBox::toggled, this, onCheck);
    connect(highlightDate_, &QCheckBox::toggled, this, onCheck);
    connect(textNames_, &QCheckBox::toggled, this, onCheck);
    connect(lightDescriptions_, &QCheckBox::toggled, this, onCheck);
    connect(textOther_, &QCheckBox::toggled, this, onCheck);
    for (auto *b : {shallow_, safety_, deep_, safetyDepth_})
        connect(b, &QDoubleSpinBox::valueChanged, this, onSpin);
}

void MarinerPanel::pull() {
    s_.scheme = static_cast<tile57_scheme>(scheme_->currentIndex());
    s_.display_standard = displayStandard_->isChecked();
    s_.display_other = displayOther_->isChecked();
    s_.depth_unit = static_cast<tile57_depth_unit>(depthUnit_->currentIndex());
    s_.boundary_style = static_cast<tile57_boundary_style>(boundaryStyle_->currentIndex());
    s_.simplified_points = simplifiedPoints_->isChecked();
    s_.four_shade_water = fourShades_->isChecked();
    s_.shallow_contour = shallow_->value();
    s_.safety_contour = safety_->value();
    s_.deep_contour = deep_->value();
    s_.safety_depth = safetyDepth_->value();
    s_.data_quality = dataQuality_->isChecked();
    s_.show_inform_callouts = infoCallouts_->isChecked();
    s_.show_meta_bounds = metaBounds_->isChecked();
    s_.show_isolated_dangers_shallow = isoDangersShallow_->isChecked();
    s_.date_dependent = dateDependent_->isChecked();
    s_.highlight_date_dependent = highlightDate_->isChecked();
    s_.text_names = textNames_->isChecked();
    s_.show_light_descriptions = lightDescriptions_->isChecked();
    s_.text_other = textOther_->isChecked();
    emit changed(s_);
}

} // namespace cpn

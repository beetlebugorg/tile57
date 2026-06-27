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

MarinerPanel::MarinerPanel(const chartstyle::MarinerSettings &initial, QWidget *parent)
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
    displayBase_->setChecked(s_.displayBase);
    displayBase_->setEnabled(false); // base is always shown
    displayBase_->setToolTip(QStringLiteral("Display Base is always shown"));
    catCol->addWidget(displayBase_);
    displayStandard_ = new QCheckBox(QStringLiteral("Standard"));
    displayStandard_->setChecked(s_.displayStandard);
    catCol->addWidget(displayStandard_);
    displayOther_ = new QCheckBox(QStringLiteral("Other"));
    displayOther_->setChecked(s_.displayOther);
    catCol->addWidget(displayOther_);
    root->addWidget(catBox);

    // -- Depth --
    auto *depthBox = new QGroupBox(QStringLiteral("Depth"));
    auto *depthForm = new QFormLayout(depthBox);
    tidyForm(depthForm);
    depthUnit_ = new QComboBox;
    depthUnit_->addItems({QStringLiteral("Metres"), QStringLiteral("Feet")});
    depthUnit_->setCurrentIndex(static_cast<int>(s_.depthUnit));
    depthForm->addRow(QStringLiteral("Units"), depthUnit_);
    fourShades_ = new QCheckBox(QStringLiteral("Four depth shades"));
    fourShades_->setChecked(s_.fourShadeWater);
    depthForm->addRow(fourShades_);
    shallow_ = metresBox(s_.shallowContour);
    depthForm->addRow(QStringLiteral("Shallow contour"), shallow_);
    safety_ = metresBox(s_.safetyContour);
    depthForm->addRow(QStringLiteral("Safety contour"), safety_);
    deep_ = metresBox(s_.deepContour);
    depthForm->addRow(QStringLiteral("Deep contour"), deep_);
    safetyDepth_ = metresBox(s_.safetyDepth);
    depthForm->addRow(QStringLiteral("Safety depth"), safetyDepth_);
    root->addWidget(depthBox);

    // -- Text (S-52 §14.5 text groups) --
    auto *textBox = new QGroupBox(QStringLiteral("Text"));
    auto *textCol = new QVBoxLayout(textBox);
    textCol->setContentsMargins(12, 10, 12, 12);
    textCol->setSpacing(8);
    textNames_ = new QCheckBox(QStringLiteral("Names"));
    textNames_->setChecked(s_.textNames);
    textCol->addWidget(textNames_);
    lightDescriptions_ = new QCheckBox(QStringLiteral("Light descriptions"));
    lightDescriptions_->setChecked(s_.showLightDescriptions);
    textCol->addWidget(lightDescriptions_);
    textOther_ = new QCheckBox(QStringLiteral("Other text"));
    textOther_->setChecked(s_.textOther);
    textCol->addWidget(textOther_);
    root->addWidget(textBox);

    // -- Overlays --
    auto *ovBox = new QGroupBox(QStringLiteral("Overlays"));
    auto *ovForm = new QVBoxLayout(ovBox);
    ovForm->setContentsMargins(12, 10, 12, 12);
    ovForm->setSpacing(8);
    dataQuality_ = new QCheckBox(QStringLiteral("Data quality (CATZOC)"));
    dataQuality_->setChecked(s_.dataQuality);
    ovForm->addWidget(dataQuality_);
    infoCallouts_ = new QCheckBox(QStringLiteral("Information callouts"));
    infoCallouts_->setChecked(s_.showInformCallouts);
    ovForm->addWidget(infoCallouts_);
    metaBounds_ = new QCheckBox(QStringLiteral("Cell / coverage boundaries"));
    metaBounds_->setChecked(s_.showMetaBounds);
    ovForm->addWidget(metaBounds_);
    isoDangersShallow_ = new QCheckBox(QStringLiteral("Isolated dangers in shallow water"));
    isoDangersShallow_->setChecked(s_.showIsolatedDangersShallow);
    ovForm->addWidget(isoDangersShallow_);
    root->addWidget(ovBox);

    // -- Date-dependent display (S-52 §10.4.1.1) --
    auto *dateBox = new QGroupBox(QStringLiteral("Dates"));
    auto *dateCol = new QVBoxLayout(dateBox);
    dateCol->setContentsMargins(12, 10, 12, 12);
    dateCol->setSpacing(8);
    dateDependent_ = new QCheckBox(QStringLiteral("Hide features out of date"));
    dateDependent_->setChecked(s_.dateDependent);
    dateCol->addWidget(dateDependent_);
    highlightDate_ = new QCheckBox(QStringLiteral("Highlight date-dependent"));
    highlightDate_->setChecked(s_.highlightDateDependent);
    dateCol->addWidget(highlightDate_);
    root->addWidget(dateBox);

    root->addStretch(1);

    // Every control funnels through pull(): read all controls into s_, emit changed.
    const auto onCombo = [this](int) { pull(); };
    const auto onCheck = [this](bool) { pull(); };
    const auto onSpin = [this](double) { pull(); };
    connect(scheme_, &QComboBox::currentIndexChanged, this, onCombo);
    connect(depthUnit_, &QComboBox::currentIndexChanged, this, onCombo);
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
    s_.scheme = static_cast<chartstyle::Scheme>(scheme_->currentIndex());
    s_.displayStandard = displayStandard_->isChecked();
    s_.displayOther = displayOther_->isChecked();
    s_.depthUnit = static_cast<chartstyle::DepthUnit>(depthUnit_->currentIndex());
    s_.fourShadeWater = fourShades_->isChecked();
    s_.shallowContour = shallow_->value();
    s_.safetyContour = safety_->value();
    s_.deepContour = deep_->value();
    s_.safetyDepth = safetyDepth_->value();
    s_.dataQuality = dataQuality_->isChecked();
    s_.showInformCallouts = infoCallouts_->isChecked();
    s_.showMetaBounds = metaBounds_->isChecked();
    s_.showIsolatedDangersShallow = isoDangersShallow_->isChecked();
    s_.dateDependent = dateDependent_->isChecked();
    s_.highlightDateDependent = highlightDate_->isChecked();
    s_.textNames = textNames_->isChecked();
    s_.showLightDescriptions = lightDescriptions_->isChecked();
    s_.textOther = textOther_->isChecked();
    emit changed(s_);
}

} // namespace cpn

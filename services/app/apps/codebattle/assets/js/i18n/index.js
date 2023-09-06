/* eslint-disable global-require */
import Gon from 'gon';
import i18next from 'i18next';

const lng = (Gon.getAsset('locale') || navigator.language || navigator.userLanguage).slice(0, 2);

export const getLocale = () => lng;

i18next.init({
  nsSeparator: false,
  keySeparator: false,
  lng: 'en',
  interpolation: {
    prefix: '%{',
    suffix: '}',
  },
  resources: {
    en: {
      translation: require('../../../priv/gettext/en/LC_MESSAGES/default.po'),
    },
  },
});

export default i18next;

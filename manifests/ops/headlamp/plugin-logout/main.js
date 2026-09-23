// Plugin do Headlamp: botao "Sair" no app bar.
//
// Por que existe: o Headlamp nao tem logout no servidor (o botao nativo so
// limpa o token local dele), e a sessao real e o cookie _oauth2_proxy. Este
// botao leva a /oauth2/sign_out, que limpa esse cookie, e em seguida ao
// end-session do Authentik (encerra tambem a sessao SSO) e volta para o
// headlamp.lan.
//
// Escrito a mao como UMD: o Headlamp carrega o main.js do plugin como script e
// injeta os modulos compartilhados em window.pluginLib (React, MuiMaterial,
// registerAppBarAction, ...). Nao precisa de toolchain/npm.
(function (global, factory) {
  if (typeof exports === 'object' && typeof module !== 'undefined') {
    module.exports = factory(require('@kinvolk/headlamp-plugin/lib'), require('react'));
  } else if (typeof define === 'function' && define.amd) {
    define(['@kinvolk/headlamp-plugin/lib', 'react'], factory);
  } else {
    global = typeof globalThis !== 'undefined' ? globalThis : global || self;
    factory(global.pluginLib, global.pluginLib.React);
  }
})(this, function (pluginLib, React) {
  'use strict';

  var registerAppBarAction = pluginLib.registerAppBarAction;
  var Button = pluginLib.MuiMaterial.Button;

  // Logout completo: limpa o cookie do proxy e encerra a sessao no Authentik,
  // voltando para o Headlamp (que pede login de novo).
  var LOGOUT_URL =
    '/oauth2/sign_out?rd=' +
    encodeURIComponent(
      'https://authentik.lan/application/o/headlamp/end-session/?next=https://headlamp.lan/'
    );

  function LogoutButton() {
    return React.createElement(
      Button,
      {
        color: 'inherit',
        size: 'small',
        onClick: function () {
          window.location.href = LOGOUT_URL;
        },
        title: 'Sair (encerra a sessao no Authentik)',
      },
      'Sair'
    );
  }

  registerAppBarAction(LogoutButton);
});

// Shared offline configuration for the file reader and native chat attachments.
let mathLoader;
const words = value => value.trim().split(/\s+/);
export async function mathEngine(chat = false) {
  if (mathLoader) return mathLoader;
  window.MathJax = {
    loader: { paths: { mathjax: 'omp-preview://bundle/vendor/mathjax', fonts: 'omp-preview://bundle/vendor' },
      // Keep the single-argument braket notation stable even after physics loads.
      load: ['ui/safe', '[tex]/braket', ...(chat ? ['[tex]/begingroup'] : [])] },
    startup: { typeset: false },
    tex: { tags: 'ams', maxBuffer: 16384, maxMacros: 1000,
      packages: { '[-]': ['noundefined'], '[+]': ['braket', ...(chat ? ['begingroup'] : [])] },
      // Conventional shorthands only; document-specific macros stay explicit.
      macros: { ii: '\\mathrm{i}', ee: '\\mathrm{e}', bm: ['\\boldsymbol{#1}', 1],
        argmin: '\\operatorname*{arg\\,min}', argmax: '\\operatorname*{arg\\,max}',
        sgn: '\\operatorname{sgn}', diag: '\\operatorname{diag}',
        ...(chat ? { qquad: '\\quad' } : {}) },
      autoload: {
        // MathJax does not autoload these bundled packages by default. Register
        // macros AND environments so the first use works in a fresh renderer.
        mathtools: [words(`shoveleft shoveright xleftrightarrow xLeftarrow xRightarrow xLeftrightarrow
          xhookleftarrow xhookrightarrow xmapsto xrightharpoondown xleftharpoondown xrightleftharpoons
          xrightharpoonup xleftharpoonup xleftrightharpoons xlongrightarrow xlongleftarrow xLongrightarrow
          xLongleftarrow mathllap mathrlap mathclap clap textllap textrlap textclap cramped crampedllap
          crampedrlap crampedclap crampedsubstack mathmbox mathmakebox overbracket underbracket refeq MoveEqLeft Aboxed
          MakeAboxedCommand ArrowBetweenLines vdotswithin shortvdotswithin MTFlushSpaceAbove MTFlushSpaceBelow
          DeclarePairedDelimiter DeclarePairedDelimiterX DeclarePairedDelimiterXPP DeclarePairedDelimiters
          DeclarePairedDelimitersX DeclarePairedDelimitersXPP vcentercolon ordinarycolon MTThinColon coloneqq
          Coloneqq coloneq Coloneq eqqcolon Eqqcolon eqcolon Eqcolon colonapprox Colonapprox colonsim Colonsim
          dblcolon approxcolon Approxcolon simcolon Simcolon colondash Colondash dashcolon Dashcolon
          nuparrow ndownarrow bigtimes splitfrac splitdfrac xmathstrut prescript newtagform renewtagform
          usetagform adjustlimits mathtoolsset`),
        words(`dcases rcases drcases dcases* rcases* drcases* cases* matrix* pmatrix* bmatrix* Bmatrix*
          vmatrix* Vmatrix* smallmatrix* psmallmatrix psmallmatrix* bsmallmatrix bsmallmatrix* Bsmallmatrix
          Bsmallmatrix* vsmallmatrix vsmallmatrix* Vsmallmatrix Vsmallmatrix* crampedsubarray multlined
          spreadlines lgathered rgathered`)],
        // Omit existing base/braket names: their meanings must not become an
        // autoload trigger for the physics package (e.g. arithmetic \div).
        physics: words(`qty quantity pqty bqty Bqty vqty absolutevalue abs norm evaluated eval order
          commutator comm anticommutator acomm poissonbracket pb dotproduct vdot crossproduct cross cp
          gradientnabla divsymbol divisionsymbol real imaginary vnabla vectorbold vb vectorarrow va
          vectorunit vu gradient grad divergence curl laplacian diffd differential dd variation var
          derivative dv partialderivative pderivative pdv functionalderivative fderivative fdv flatfrac
          trace tr Trace Tr rank erf Residue Res principalvalue pv PV sine hypsine arcsine asine cosine
          hypcosine arccosine acosine tangent hyptangent arctangent atangent cosecant hypcosecant arccosecant
          acosecant secant hypsecant arcsecant asecant cotangent hypcotangent arccotangent acotangent
          csch sech arccsc acsc arcsec asec arccot acot asin acos atan exponential logarithm naturallogarithm
          determinant Probability qqtext qq qc qcc qcomma qgiven qassume qusing qotherwise qunless qif qthen qelse
          qsince qlet qfor qall qeven qodd qinteger qand qor qas qin innerproduct ip outerproduct dyad op
          expectationvalue expval ev matrixelement matrixel mel matrixquantity mqty pmqty Pmqty bmqty vmqty
          smallmatrixquantity smqty spmqty sPmqty sbmqty svmqty matrixdeterminant mdet smdet identitymatrix
          imat xmatrix xmat zeromatrix zmat paulimatrix pmat diagonalmatrix dmat antidiagonalmatrix admat`),
        bbm: ['mathbbm', 'mathbbmss', 'mathbbmtt'], dsfont: ['mathds'],
        units: ['units', 'unitfrac', 'nicefrac'],
        gensymb: ['degree', 'celsius', 'ohm', 'perthousand', 'micro'],
        centernot: ['centernot', 'centerOver'],
        upgreek: words(`upalpha upbeta upchi updelta Updelta upepsilon upeta upgamma Upgamma upiota upkappa
          uplambda Uplambda upmu upnu upomega Upomega upomicron upphi Upphi uppi Uppi uppsi Uppsi uprho
          upsigma Upsigma uptau uptheta Uptheta upupsilon Upupsilon upvarepsilon upvarphi upvarpi upvarrho
          upvarsigma upvartheta upxi Upxi upzeta`)
      },
      inlineMath: [['\\(', '\\)']], displayMath: [['\\[', '\\]']],
      processEscapes: false },
    output: { font: 'mathjax-newcm', fontPath: 'omp-preview://bundle/vendor/mathjax-newcm',
      displayOverflow: 'scroll', linebreaks: { inline: true } },
    options: { enableMenu: false, enableExplorer: false, enableEnrichment: false,
      enableSpeech: false, enableBraille: false, enableComplexity: false,
      // The menu component initializes a11y from its settings even when the
      // menu is hidden. Keep it from starting speech workers in an offline view.
      menuOptions: { settings: { enrich: false, speech: false, braille: false, collapsible: false, assistiveMml: false } },
      ignoreHtmlClass: '.*', processHtmlClass: 'math',
      safeOptions: { allow: { URLs: 'safe', classes: 'none', cssIDs: 'none', styles: 'none' },
        safeProtocols: { http: true, https: true, mailto: true, file: false, javascript: false, data: false } } }
  };
  mathLoader = new Promise((resolve, reject) => {
    const script = document.createElement('script');
    script.src = 'vendor/mathjax/tex-chtml.js';
    script.onload = () => window.MathJax.startup.promise.then(resolve, reject);
    script.onerror = reject;
    document.head.append(script);
  });
  return mathLoader;
}


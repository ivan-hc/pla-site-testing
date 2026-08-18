document.addEventListener('DOMContentLoaded', function () {
  var carousel = document.getElementById('app-carousel');
  if (!carousel) return;

  var track = carousel.querySelector('.carousel-track');
  var slides = carousel.querySelectorAll('.carousel-slide');
  var prevBtn = carousel.querySelector('.carousel-prev');
  var nextBtn = carousel.querySelector('.carousel-next');
  var dotsWrap = carousel.querySelector('.carousel-dots');
  var AUTOPLAY_MS = 6000;
  var index = 0;
  var timer = null;

  if (!track || slides.length < 2) return;

  var dots = [];
  for (var i = 0; i < slides.length; i++) {
    (function (i) {
      var dot = document.createElement('button');
      dot.type = 'button';
      dot.className = 'carousel-dot';
      dot.setAttribute('aria-label', 'Go to slide ' + (i + 1));
      dot.addEventListener('click', function () {
        goTo(i);
        restart();
      });
      dotsWrap.appendChild(dot);
      dots.push(dot);
    })(i);
  }

  function goTo(n) {
    index = (n + slides.length) % slides.length;
    track.style.transform = 'translateX(-' + index * 100 + '%)';
    for (var i = 0; i < slides.length; i++) {
      slides[i].setAttribute('aria-hidden', i === index ? 'false' : 'true');
      dots[i].classList.toggle('active', i === index);
      dots[i].setAttribute('aria-current', i === index ? 'true' : 'false');
    }
  }

  function start() {
    if (timer) return;
    timer = setInterval(function () { goTo(index + 1); }, AUTOPLAY_MS);
  }

  function stop() {
    if (timer) {
      clearInterval(timer);
      timer = null;
    }
  }

  function restart() {
    stop();
    start();
  }

  prevBtn.addEventListener('click', function () { goTo(index - 1); restart(); });
  nextBtn.addEventListener('click', function () { goTo(index + 1); restart(); });

  carousel.addEventListener('mouseenter', stop);
  carousel.addEventListener('mouseleave', start);
  carousel.addEventListener('focusin', stop);
  carousel.addEventListener('focusout', start);

  goTo(0);

  if (!window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
    start();
  }
});

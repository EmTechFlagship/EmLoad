import { steps } from "../data/site";
import { Icon } from "./Icon";

export function HowItWorks() {
  return (
    <section className="section section--tinted" id="how">
      <div className="container">
        <div className="section-head reveal">
          <span className="section-kicker">Up and running</span>
          <h2>
            Three steps. <span className="accent-2">No ceremony.</span>
          </h2>
          <p>From download to first install in a few minutes.</p>
        </div>

        <div className="steps">
          {steps.map((step) => (
            <article className="step reveal" key={step.num}>
              <span className="step-num">{step.num}</span>
              <span className="step-icon">
                <Icon name={step.icon} />
              </span>
              <h3>{step.title}</h3>
              <p>{step.body}</p>
              <span className="step-foot">{step.foot}</span>
            </article>
          ))}
        </div>
      </div>
    </section>
  );
}

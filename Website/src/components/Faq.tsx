import { useState } from "react";
import { faqs } from "../data/site";
import { Icon } from "./Icon";

export function Faq() {
  const [openIndex, setOpenIndex] = useState(0);

  return (
    <section className="section section--tinted" id="faq">
      <div className="container faq-layout">
        <div className="section-head reveal">
          <span className="section-kicker">Good to know</span>
          <h2 aria-label="Questions, answered.">
            Questions,
            <br />
            <span className="accent-2">answered.</span>
          </h2>
          <p>Everything you need to know before your first install.</p>
        </div>

        <div className="faq-list reveal">
          {faqs.map((faq, index) => {
            const open = openIndex === index;
            return (
              <details className="faq-item" key={faq.question} open={open}>
                <summary
                  onClick={(event) => {
                    event.preventDefault();
                    setOpenIndex(open ? -1 : index);
                  }}
                >
                  <span>{faq.question}</span>
                  <span className="faq-icon" aria-hidden="true">
                    <Icon name="plus" />
                  </span>
                </summary>
                <div className="faq-body">
                  <p>{faq.answer}</p>
                </div>
              </details>
            );
          })}
        </div>
      </div>
    </section>
  );
}

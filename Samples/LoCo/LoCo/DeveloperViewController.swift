//
//  DeveloperViewController.swift
//  LoCo
//
//  Created by Drew McCormack on 22/05/2019.
//  Copyright © 2019 The Mental Faculty B.V. All rights reserved.
//

import UIKit

class DeveloperViewController: UIViewController {

    @IBOutlet weak var errorTextView: UITextView!
    
    var contactBook: ContactBook!
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        errorTextView.text = contactBook.lastSyncError ?? "No error."
    }
    
    @IBAction func dismiss(_ sender: Any) {
        dismiss(animated: true, completion: nil)
    }
    
}
